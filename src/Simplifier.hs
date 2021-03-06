{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}

module Simplifier
  ( Pattern (..),
    Literal (..),
    ConstructorDefinition (..),
    SimplifierError (..),
    AST (..),
    Expr (..),
    ValueDefinition (..),
    Name,
    ValName,
    TypeVar,
    ConstructorName,
    TypeName,
    Builtin (..),
    HasConstructorMap (..),
    ConstructorInfo (..),
    ConstructorMap,
    isConstructor,
    lookupConstructorOrFail,
    simplifier,
  )
where

import Control.Monad (forM_, replicateM, unless, when)
import Control.Monad.Except (Except, MonadError (..), liftEither, runExcept)
import Control.Monad.Reader (MonadReader (..), ReaderT (..), ask, asks, local)
import Control.Monad.State (MonadState, StateT (..), execStateT, get, gets, modify', put)
import Data.Foldable (asum)
import Data.Function (on)
import Data.List (elemIndex, foldl', groupBy, transpose)
import qualified Data.Map as Map
import Data.Maybe (catMaybes)
import qualified Data.Set as Set
import Ourlude
import Parser (ConstructorDefinition (..), ConstructorName, Literal (..), Name, ValName)
import qualified Parser as P
import Types (FreeTypeVars (..), Scheme (..), Type (..), TypeName, TypeVar, closeType)

-- | The kind of error that can happen while simplifying
data SimplifierError
  = -- | Multiple type annotations are present for the same value
    MultipleTypeAnnotations ValName [Scheme]
  | -- | Different pattern lengths have been observed for the same function definition
    DifferentPatternLengths ValName [Int]
  | -- | An annotation doesn't have a corresponding definition
    UnimplementedAnnotation ValName
  | -- | A type variable is not bound in a constructor
    UnboundTypeVarsInConstructor [TypeVar] ConstructorName
  | -- | A reference to some type that doesn't exist
    UnknownType TypeName
  | -- | A mismatch of a type constructor with expected vs actual args
    MismatchedTypeArgs TypeName Int Int
  | -- | A type synonym ends up being cyclical
    CyclicalTypeSynonym TypeName [TypeName]
  | -- | We tried to lookup a constructor that doesn't exist
    UnknownConstructor ConstructorName
  deriving (Eq, Show)

-- | The AST we return after the simplifier stage
--
-- This is paremeterized over what kind of type annotations are present in our AST.
--
-- We've grouped global information about types from the definitions into a central map.
-- The remaining definitions in our AST are for values.
data AST t = AST ConstructorMap [ValueDefinition t] deriving (Eq, Show)

-- | The information we have about a given constructor
data ConstructorInfo = ConstructorInfo
  { -- | The arity i.e. number of arguments that the constructor takes
    --
    -- This information is in the type, but much more convenient to have readily available
    constructorArity :: Int,
    -- | The type of this constructor, as a function
    constructorType :: Scheme,
    -- | The number / tag this constructor has
    constructorNumber :: Int
  }
  deriving (Eq, Show)

-- | A ConstructorMap is a map from constructor names to information about them
type ConstructorMap = Map.Map ConstructorName ConstructorInfo

-- | Represents the information we might have when resolving a type name
data ResolvingInformation
  = -- | The name is a synonym for a fully resolved expression
    Synonym Type
  | -- | The name is a custom type with a certain arity
    Custom Int
  deriving (Eq, Show)

-- | A resolution map provides us with information about each type appearing in our program
type ResolutionMap = Map.Map TypeName ResolvingInformation

-- | A class for monadic contexts with access to type information
class Monad m => HasConstructorMap m where
  -- | Access the type information available in this context
  constructorMap :: m ConstructorMap

-- | Given a resolution map, fully resolve a type, or throw an error
--
-- This replaces all references to synonyms with concrete types.
resolve :: ResolutionMap -> Type -> Either SimplifierError Type
resolve mp = go
  where
    go :: Type -> Either SimplifierError Type
    go = \case
      CustomType name ts -> do
        ts' <- mapM go ts
        let arity = length ts'
        case Map.lookup name mp of
          Nothing -> Left (UnknownType name)
          Just (Synonym _) | arity /= 0 -> Left (MismatchedTypeArgs name 0 arity)
          Just (Synonym t) -> return t
          Just (Custom expected) | arity /= expected -> Left (MismatchedTypeArgs name expected arity)
          Just (Custom _) -> return (CustomType name ts')
      t1 :-> t2 -> (:->) <$> go t1 <*> go t2
      terminal -> return terminal

-- | Check if some name is a constructor
isConstructor :: HasConstructorMap m => Name -> m Bool
isConstructor name =
  Map.member name <$> constructorMap

-- | Lookup the information about a given constructor
--
-- This should be called only after having made sure the construct exists
lookupConstructorOrFail :: HasConstructorMap m => ConstructorName -> m ConstructorInfo
lookupConstructorOrFail name =
  Map.findWithDefault err name <$> constructorMap
  where
    err = UnknownConstructor name |> show |> error

-- | Represents a single definition for a value.
--
-- This is parameterized over the kind of type annotations appearing in our definitions.
--
-- We have a name for this definition, a potential type annotation provided by the user,
-- a type annotation provided by us, and an expression appearing on the right side of this definition.
data ValueDefinition t = ValueDefinition ValName (Maybe Scheme) t (Expr t) deriving (Eq, Show)

-- | Represents a builtin operation in our language
data Builtin
  = Add
  | Sub
  | Mul
  | Div
  | Compose
  | Concat
  | Cash
  | Less
  | LessEqual
  | Greater
  | GreaterEqual
  | EqualTo
  | NotEqualTo
  | And
  | Or
  | Negate
  deriving (Eq, Show)

-- | Represents a kind of expression in our language
data Expr t
  = LetExpr [ValueDefinition t] (Expr t)
  | CaseExpr (Expr t) [(Pattern, Expr t)]
  | Error String
  | LitExpr Literal
  | Builtin Builtin
  | NameExpr Name
  | ApplyExpr (Expr t) (Expr t)
  | LambdaExpr ValName t (Expr t)
  deriving (Eq, Show)

-- | Represents a pattern that appears in a case expression
--
-- Unlike in the parser, patterns are completely flat. They cannot
-- contain further nested patterns. One big job of this module is
-- is to remove the nesting present in the parser.
--
-- Note that simple name patterns don't appear here. This is because
-- our simplification process replaces that with a wildcard, and uses
-- the scrutinee in the body of that branch instead.
data Pattern
  = Wildcard
  | LiteralPattern Literal
  | ConstructorPattern ConstructorName [ValName]
  deriving (Eq, Show)

-- | Substitute a name for an expression, replacing all of its occurrences
--
-- This respects lexical scoping rules, so won't replace bindings that shadow
-- this one.
substituteName :: Name -> Expr t -> Expr t -> Expr t
substituteName old new = go
  where
    names :: [ValueDefinition t] -> [Name]
    names = map (\(ValueDefinition n _ _ _) -> n)

    go (NameExpr name) | name == old = new
    go (ApplyExpr f e) = ApplyExpr (go f) (go e)
    go (CaseExpr scrut branches) =
      CaseExpr (go scrut) (map (second go) branches)
    go (LambdaExpr name t e) | name /= old = LambdaExpr name t (go e)
    go (LetExpr defs e)
      | old `notElem` names defs =
        let changeDef (ValueDefinition n dec t e') = ValueDefinition n dec t (go e')
         in LetExpr (map changeDef defs) (go e)
    go terminal = terminal

{- Gathering Type Information -}

-- | Create a map for constructor information
--
-- We need the ability to throw simplifier errors to do this.
gatherConstructorMap :: [P.Definition] -> Either SimplifierError ConstructorMap
gatherConstructorMap =
  foldMapM <| \case
    P.DataDefinition name typeVars definitions ->
      let root = CustomType name (map TVar typeVars)
       in foldMapM (makeMap typeVars root) (zip definitions [0 ..])
    _ -> return Map.empty
  where
    makeMap :: MonadError SimplifierError m => [TypeVar] -> Type -> (ConstructorDefinition, Int) -> m ConstructorMap
    makeMap typeVars ret (P.ConstructorDefinition cstr types, number) = do
      let arity = length types
          scheme = Scheme typeVars (foldr (:->) ret types)
          info = ConstructorInfo arity scheme number
          freeInScheme = ftv scheme
      unless (null freeInScheme)
        <| throwError (UnboundTypeVarsInConstructor (Set.toList freeInScheme) cstr)
      return (Map.singleton cstr info)

resolveConstructorMap :: ResolutionMap -> ConstructorMap -> Either SimplifierError ConstructorMap
resolveConstructorMap mp =
  traverse
    <| \(ConstructorInfo arity (Scheme vars t) number) -> do
      resolved <- resolve mp t
      return (ConstructorInfo arity (Scheme vars resolved) number)

{- Resolving all of the type synonyms -}

-- | Which type definitions does this type reference?
typeDependencies :: Type -> Set.Set TypeName
typeDependencies = \case
  t1 :-> t2 -> typeDependencies t1 <> typeDependencies t2
  CustomType name exprs -> Set.singleton name <> foldMap typeDependencies exprs
  _ -> mempty

-- | This is the state we keep track of while sorting the graph of types
data SorterState = SorterState
  { -- | All of the type names we haven't seen yet
    unseen :: Set.Set TypeName,
    -- | The current output we've generated so far
    output :: [TypeName]
  }

-- | The context in which the topological sorting of the type graph takes place
--
-- We have access to a set of ancestors to keep track of cycles, the current state,
-- which we can modify, and the ability to throw exceptions.
type SorterM a = ReaderT (Set.Set TypeName) (StateT SorterState (Except SimplifierError)) a

-- | Run the sorter, given a seed state
runSorter :: SorterM a -> SorterState -> Either SimplifierError a
runSorter m st =
  runReaderT m Set.empty |> (`runStateT` st) |> runExcept |> fmap fst

-- | Given a mapping from names to shallow types, find a linear ordering of these types
--
-- The types are sorted topologically, based on their dependencies. This means that
-- a type will come after all of its dependencies
sortTypeSynonyms :: Map.Map TypeName Type -> Either SimplifierError [TypeName]
sortTypeSynonyms mp = runSorter sort (SorterState (Map.keysSet mp) []) |> fmap reverse
  where
    deps :: TypeName -> Set.Set TypeName
    deps k = Map.findWithDefault Set.empty k (Map.map typeDependencies mp)

    see :: TypeName -> SorterM Bool
    see name = do
      unseen' <- gets unseen
      modify' (\s -> s {unseen = Set.delete name unseen'})
      return (Set.member name unseen')

    out :: TypeName -> SorterM ()
    out name = modify' (\s -> s {output = name : output s})

    withAncestor :: TypeName -> SorterM a -> SorterM a
    withAncestor = local <<< Set.insert

    sort :: SorterM [TypeName]
    sort = do
      unseen' <- gets unseen
      case Set.lookupMin unseen' of
        Nothing -> gets output
        Just n -> do
          dfs n
          sort

    dfs :: TypeName -> SorterM ()
    dfs name = do
      ancestors <- ask
      when
        (Set.member name ancestors)
        (throwError (CyclicalTypeSynonym name (Set.toList ancestors)))
      new <- see name
      when new <| do
        withAncestor name (forM_ (deps name) dfs)
        out name

-- | Gather all of the custom types, along with the number of arguments they contain
gatherCustomTypes :: [P.Definition] -> Map.Map TypeName Int
gatherCustomTypes =
  foldMap <| \case
    P.DataDefinition name vars _ -> Map.singleton name (length vars)
    _ -> Map.empty

-- | Gather all of the type synonyms, at a superficial level
--
-- This will only look at one level of definition, and won't act recursively
gatherTypeSynonyms :: [P.Definition] -> Map.Map TypeName Type
gatherTypeSynonyms =
  foldMap <| \case
    P.TypeSynonym name expr -> Map.singleton name expr
    _ -> Map.empty

-- | A monad we use for gathering a resolution map
type MakeResolutionM a = ReaderT (Map.Map TypeName Type) (StateT ResolutionMap (Except SimplifierError)) a

-- | Gather all the resolving information from types
gatherResolutions :: [P.Definition] -> Either SimplifierError ResolutionMap
gatherResolutions defs = do
  let customInfo = gatherCustomTypes defs
      typeSynMap = gatherTypeSynonyms defs
  names <- sortTypeSynonyms typeSynMap
  runResolutionM (resolveAll names) typeSynMap (Map.map Custom customInfo)
  where
    runResolutionM :: MakeResolutionM a -> Map.Map TypeName Type -> ResolutionMap -> Either SimplifierError ResolutionMap
    runResolutionM m typeSynMap st =
      runReaderT m typeSynMap |> (`execStateT` st) |> runExcept

    resolveAll :: [TypeName] -> MakeResolutionM ()
    resolveAll =
      mapM_ <| \n ->
        asks (Map.lookup n) >>= \case
          Nothing -> throwError (UnknownType n)
          Just unresolved -> do
            resolutions' <- get
            resolved <- liftEither (resolve resolutions' unresolved)
            modify' (Map.insert n (Synonym resolved))

data SimplifierContext = SimplifierContext
  { resolutionMap :: ResolutionMap,
    constructorInfo :: ConstructorMap
  }

-- | Represents the context we have access to in the simplifier
--
-- We do this in order to keep a global source of fresh variables
newtype Simplifier a = Simplifier (ReaderT SimplifierContext (StateT Int (Except SimplifierError)) a)
  deriving (Functor, Applicative, Monad, MonadReader SimplifierContext, MonadState Int, MonadError SimplifierError)

-- | Run the simplifier, producing an error, or value
runSimplifier :: SimplifierContext -> Simplifier a -> Either SimplifierError a
runSimplifier ctx (Simplifier m) = runReaderT m ctx |> (`runStateT` 0) |> runExcept |> fmap fst

instance HasConstructorMap Simplifier where
  constructorMap = asks constructorInfo

-- | Create a fresh name in the simplifier context
fresh :: Simplifier ValName
fresh = do
  c <- get
  put (c + 1)
  return ("$" ++ show c)

makeScheme :: Type -> Simplifier Scheme
makeScheme typ = do
  mp <- asks resolutionMap
  resolved <- liftEither (resolve mp typ)
  return (closeType resolved)

validatePattern :: P.Pattern -> Simplifier ()
validatePattern = \case
  P.ConstructorPattern name pats -> do
    ok <- isConstructor name
    unless ok (throwError (UnknownConstructor name))
    forM_ pats validatePattern
  _ -> return ()

{- Converting the actual AST and Expression Tree -}

-- | Convert an expression to a simplified expression
convertExpr :: P.Expr -> Simplifier (Expr ())
-- We replace binary expressions with the corresponding bultin functions
convertExpr (P.BinExpr op e1 e2) = do
  let b = case op of
        P.Add -> Add
        P.Sub -> Sub
        P.Mul -> Mul
        P.Div -> Div
        P.Compose -> Compose
        P.Concat -> Concat
        P.Cash -> Cash
        P.Less -> Less
        P.LessEqual -> LessEqual
        P.Greater -> Greater
        P.GreaterEqual -> GreaterEqual
        P.EqualTo -> EqualTo
        P.NotEqualTo -> NotEqualTo
        P.And -> And
        P.Or -> Or
  e1' <- convertExpr e1
  e2' <- convertExpr e2
  return (ApplyExpr (ApplyExpr (Builtin b) e1') e2')
-- Negation is replaced by a built in function as well
convertExpr (P.NegateExpr e) = ApplyExpr (Builtin Negate) <$> convertExpr e
convertExpr (P.WhereExpr e defs) =
  convertExpr (P.LetExpr defs e)
convertExpr (P.IfExpr cond thenn elsse) = do
  cond' <- convertExpr cond
  thenn' <- convertExpr thenn
  elsse' <- convertExpr elsse
  return
    ( CaseExpr
        cond'
        [ (LiteralPattern (BoolLiteral True), thenn'),
          (LiteralPattern (BoolLiteral False), elsse')
        ]
    )
convertExpr (P.NameExpr name) = return (NameExpr name)
convertExpr (P.LitExpr litt) = return (LitExpr litt)
convertExpr (P.LambdaExpr names body) = do
  body' <- convertExpr body
  return (foldr (`LambdaExpr` ()) body' names)
convertExpr (P.ApplyExpr f exprs) = do
  f' <- convertExpr f
  exprs' <- traverse convertExpr exprs
  return (foldl' ApplyExpr f' exprs')
convertExpr (P.CaseExpr expr patterns) = do
  expr' <- convertExpr expr
  forM_ patterns (fst >>> validatePattern)
  matrix <- Matrix <$> traverse (\(p, e) -> Row [p] <$> convertExpr e) patterns
  -- We're guaranteed to have a single name, because we have a single column
  (names, caseExpr) <- compileMatrix matrix
  -- We create a let, because inlining isn't necessarily desired
  return (LetExpr [ValueDefinition (head names) Nothing () expr'] caseExpr)
convertExpr (P.LetExpr defs e) = do
  defs' <- convertValueDefinitions defs
  e' <- convertExpr e
  return (LetExpr defs' e')

-- | This converts value definitions by gathering the different patterns into a single lambda expression,
-- and adding the optional type annotation if it exists.
-- This will emit errors if any discrepencies are encountered.
convertValueDefinitions :: [P.ValueDefinition] -> Simplifier [ValueDefinition ()]
convertValueDefinitions =
  groupBy ((==) `on` getName) >>> traverse gather
  where
    getName :: P.ValueDefinition -> Name
    getName = \case
      P.TypeAnnotation name _ -> name
      P.NameDefinition name _ _ -> name

    getTypeAnnotations :: [P.ValueDefinition] -> [Type]
    getTypeAnnotations ls = ls |> map pluckAnnotation |> catMaybes
      where
        pluckAnnotation = \case
          P.TypeAnnotation _ typ -> Just typ
          _ -> Nothing

    makeMatrix :: [P.ValueDefinition] -> Simplifier (Matrix (Expr ()))
    makeMatrix = traverse makeRow >>> fmap (catMaybes >>> Matrix)
      where
        makeRow = \case
          P.NameDefinition _ pats body -> do
            forM_ pats validatePattern
            body' <- convertExpr body
            return (Just (Row pats body'))
          _ -> return Nothing

    gather :: [P.ValueDefinition] -> Simplifier (ValueDefinition ())
    gather [] = error "groupBy returned empty list"
    gather valueHeads = do
      let name = getName (head valueHeads)
      annotations <- getTypeAnnotations valueHeads |> mapM makeScheme
      schemeExpr <- case annotations of
        [] -> return Nothing
        [single] -> return (Just single)
        tooMany -> throwError (MultipleTypeAnnotations name tooMany)
      matrix <- makeMatrix valueHeads
      validateMatrix name matrix
      (names, caseExpr) <- compileMatrix matrix
      let expr = foldr (`LambdaExpr` ()) caseExpr names
      return (ValueDefinition name schemeExpr () expr)

{- Pattern Matching Simplifying -}

-- | Check that a pattern is not a wildcard
notWildcard :: P.Pattern -> Bool
notWildcard P.WildcardPattern = False
notWildcard _ = True

-- | Swap the 0th element and the ith element
swap :: Int -> [a] -> [a]
swap i xs = (xs !! i) : (zip [0 ..] xs |> filter ((/= i) . fst) |> map snd)

-- This is a matrix of patterns, the representation of some match expression
--
-- This matrix might have multiple columns, as generated by a function
-- definition.
newtype Matrix a = Matrix [Row a] deriving (Eq, Show)

-- | Check that a matrix is coherent
validateMatrix :: MonadError SimplifierError m => ValName -> Matrix a -> m ()
validateMatrix name (Matrix rows) = do
  let lengths = map (rowPats >>> length) rows
      allEqual = null lengths || all (== head lengths) lengths
  unless allEqual
    <| throwError (DifferentPatternLengths name lengths)
  when (null rows)
    <|
    -- If we're validating a matrix for some name, and there are no patterns,
    -- then there are no definitions for that annotation
    throwError (UnimplementedAnnotation name)
  return ()

-- | Represents a row in our pattern matrix
data Row a = Row
  { -- | The patterns contained in this row
    rowPats :: [P.Pattern],
    -- | The value contained in this row
    rowVal :: a
  }
  deriving (Eq, Show)

-- | True if a row consists only of wild cards
allWildCards :: Row a -> Bool
allWildCards = rowPats >>> all (== P.WildcardPattern)

-- | Gather a list of patterns into a list of branches
gatherBranches :: [P.Pattern] -> [Branch]
gatherBranches = foldMap pluckHead >>> Set.toList
  where
    pluckHead :: P.Pattern -> Set.Set Branch
    pluckHead = \case
      P.LiteralPattern l ->
        Set.singleton (LiteralBranch l)
      P.ConstructorPattern name pats ->
        Set.singleton (ConstructorBranch name (length pats))
      _ -> Set.empty

-- | Get all the columns of a matrix
columns :: Matrix a -> [[P.Pattern]]
columns (Matrix rows) = rows |> map rowPats |> transpose

-- | Select the index of the next column in the matrix
nextColumn :: Matrix a -> Maybe Int
nextColumn = columns >>> map (any notWildcard) >>> elemIndex True

-- | Swap the nth column of a matrix with the first column
swapColumn :: Int -> Matrix a -> Matrix a
swapColumn index (Matrix rows) =
  let vals = map rowVal rows
      pats = map rowPats rows
      transformed = pats |> transpose |> swap index |> transpose
   in Matrix (zipWith Row transformed vals)

-- | Find the first name present in the first column of a matrix
firstName :: Matrix a -> Maybe String
firstName (Matrix rows) = map stripName rows |> asum
  where
    stripName :: Row a -> Maybe String
    stripName (Row (P.NamePattern n : _) _) = Just n
    stripName _ = Nothing

-- | Calculate the resulting matrix after choosing the default branch
defaultMatrix :: Matrix a -> Matrix a
defaultMatrix (Matrix rows) =
  rows |> filter isDefault |> map stripHead |> Matrix
  where
    isDefault :: Row a -> Bool
    isDefault = \case
      Row [] _ -> True
      Row (P.WildcardPattern : _) _ -> True
      Row (P.NamePattern _ : _) _ -> True
      _ -> False

    stripHead :: Row a -> Row a
    stripHead (Row pats a) = Row (tail pats) a

-- | Calculate the matrix resulting after taking a branch
branchMatrix :: Branch -> Matrix a -> Matrix a
branchMatrix branch (Matrix rows) =
  rows |> map (\(Row pats a) -> (`Row` a) <$> newPats pats) |> catMaybes |> Matrix
  where
    matches :: Branch -> P.Pattern -> Maybe [P.Pattern]
    matches (LiteralBranch l) (P.LiteralPattern l') | l == l' = Just []
    matches (ConstructorBranch name _) (P.ConstructorPattern name' pats)
      | name == name' =
        Just pats
    matches _ _ = Nothing

    makeWildCards :: Branch -> [P.Pattern]
    makeWildCards (LiteralBranch _) = []
    makeWildCards (ConstructorBranch _ arity) = replicate arity P.WildcardPattern

    newPats :: [P.Pattern] -> Maybe [P.Pattern]
    newPats = \case
      P.WildcardPattern : rest ->
        Just (makeWildCards branch ++ rest)
      P.NamePattern _ : rest ->
        Just (makeWildCards branch ++ rest)
      pat : rest -> (++ rest) <$> matches branch pat
      [] -> Just []

-- | Represents a decision tree we use to generate a case expression.
--
-- The idea is that the tree represents an imperative set of commands we can
-- use to advance our matches against some expressions.
data Tree a
  = -- | Represents a failure in our pattern matching process
    Fail
  | -- | Represents the output of a value
    Leaf a
  | -- | Swapping the current value in index `i` with the first value, then continue
    Swap Int (Tree a)
  | -- | Replace all occurences of a given name with the first value's name, and continue
    SubstOut Name (Tree a)
  | -- | Here we have the actual branching
    --
    -- Each of these is a distinct possibility, based on the first value.
    -- The last item is the default branch.
    Select [(Branch, Tree a)] (Tree a)
  deriving (Eq, Show)

-- | Represents a type of branch we can take in our decision tree
data Branch
  = -- A branch for a constructor of a certain arity
    ConstructorBranch ConstructorName Int
  | -- A branch for a value of literal type
    LiteralBranch Literal
  deriving (Eq, Ord, Show)

-- | Build up a decision tree from a pattern matrix
buildTree :: Matrix a -> Tree a
buildTree (Matrix []) = Fail
buildTree (Matrix (r : _)) | allWildCards r = Leaf (rowVal r)
buildTree mat = case nextColumn mat of
  Nothing -> error "There must be a non wildcard in one of the rows"
  Just 0 ->
    let col = head (columns mat)
        makeTree branch = (branch, buildTree (branchMatrix branch mat))
        branches = gatherBranches col |> map makeTree
        default' = buildTree (defaultMatrix mat)
        baseTree = Select branches default'
     in case firstName mat of
          Just n -> SubstOut n baseTree
          Nothing -> baseTree
  Just n -> Swap n (buildTree (swapColumn n mat))

-- | Fold down a decision tree yielding expressions into a final case expression
--
-- We need to know the number of initial values we're matching against,
-- and have access to the context in which we fold down trees.
foldTree :: Int -> Tree (Expr t) -> Simplifier ([ValName], Expr t)
foldTree patCount theTree = do
  names <- replicateM patCount fresh
  expr <- go names theTree
  return (names, expr)
  where
    handleBranch :: [String] -> (Branch, Tree (Expr t)) -> Simplifier (Pattern, Expr t)
    handleBranch names (branch, tree) = case branch of
      LiteralBranch l -> (LiteralPattern l,) <$> go names tree
      ConstructorBranch cstr arity -> do
        newNames <- replicateM arity fresh
        expr <- go (newNames ++ names) tree
        return (ConstructorPattern cstr newNames, expr)

    go :: [ValName] -> Tree (Expr t) -> Simplifier (Expr t)
    go names tree = case tree of
      Fail -> return (Error "Pattern Match Failure")
      Leaf expr -> return expr
      Swap i tree' -> go (swap i names) tree'
      SubstOut old tree' -> substituteName old (NameExpr (head names)) <$> go names tree'
      Select branches default' -> do
        let rest = tail names
            scrut = NameExpr (head names)
        branchCases <- traverse (handleBranch rest) branches
        defaultExpr <- go rest default'
        return <| case branchCases of
          [] -> defaultExpr
          _ -> CaseExpr scrut (branchCases ++ [(Wildcard, defaultExpr)])

-- | Compile a pattern matrix into a list of lambda names, and an expression using pattern matching
compileMatrix :: Matrix (Expr t) -> Simplifier ([ValName], Expr t)
compileMatrix mat@(Matrix rows) =
  let patCount = length (rowPats (head rows))
   in buildTree mat |> foldTree patCount

{- Glueing it all together -}

-- | Convert a list of definitions into a list of sipmlified definitions
convertDefinitions :: [P.Definition] -> Simplifier [ValueDefinition ()]
convertDefinitions = map pluckValueDefinition >>> catMaybes >>> convertValueDefinitions
  where
    pluckValueDefinition :: P.Definition -> Maybe P.ValueDefinition
    pluckValueDefinition (P.ValueDefinition v) = Just v
    pluckValueDefinition _ = Nothing

simplifier :: P.AST -> Either SimplifierError (AST ())
simplifier (P.AST defs) = do
  resolutionMap' <- gatherResolutions defs
  constructorMap' <- gatherConstructorMap defs
  resolvedConstructors <- resolveConstructorMap resolutionMap' constructorMap'
  let ctx = SimplifierContext resolutionMap' resolvedConstructors
  runSimplifier ctx <| do
    defs' <- convertDefinitions defs
    return (AST resolvedConstructors defs')
