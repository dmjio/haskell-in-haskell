{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}

module Simplifier
  ( Pattern (..),
    Litteral (..),
    TypeExpr (..),
    SchemeExpr (..),
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
    ResolutionError,
    HasTypeInformation (..),
    ResolutionM (..),
    TypeInformation (..),
    ConstructorInfo (..),
    resolveM,
    lookupConstructor,
    simplifier,
  )
where

import Control.Monad (forM_, replicateM, when)
import Control.Monad.Except (Except, MonadError (..), liftEither, runExcept)
import Control.Monad.Reader (ReaderT (..), ask, asks, local)
import Control.Monad.State (MonadState, State, StateT (..), execStateT, get, gets, modify', put, runState)
import Data.Foldable (asum)
import Data.Function (on)
import Data.List (elemIndex, foldl', groupBy, transpose)
import qualified Data.Map as Map
import Data.Maybe (catMaybes)
import qualified Data.Set as Set
import Ourlude
import Parser (ConstructorDefinition (..), ConstructorName, Litteral (..), Name, TypeExpr (..), TypeName, TypeVar, ValName)
import qualified Parser as P

data AST t = AST TypeInformation [ValueDefinition t] deriving (Eq, Show)

data ValueDefinition t = ValueDefinition ValName (Maybe SchemeExpr) t (Expr t) deriving (Eq, Show)

data SchemeExpr = SchemeExpr [TypeVar] TypeExpr deriving (Eq, Show)

closeTypeExpr :: TypeExpr -> SchemeExpr
closeTypeExpr t = SchemeExpr (names t |> Set.toList) t
  where
    names StringType = Set.empty
    names IntType = Set.empty
    names BoolType = Set.empty
    names (CustomType _ typs) = foldMap names typs
    names (TypeVar n) = Set.singleton n
    names (t1 :-> t2) = names t1 <> names t2

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

data Expr t
  = LetExpr [ValueDefinition t] (Expr t)
  | CaseExpr (Expr t) [(Pattern, Expr t)]
  | Error String
  | LittExpr Litteral
  | Builtin Builtin
  | NameExpr Name
  | ApplyExpr (Expr t) (Expr t)
  | LambdaExpr ValName t (Expr t)
  deriving (Eq, Show)

data Pattern
  = LitteralPattern Litteral
  | Wildcard
  | ConstructorPattern ConstructorName [Name]
  deriving (Eq, Show)

subst :: Name -> Expr t -> Expr t -> Expr t
subst old new = go
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

data SimplifierError
  = -- Multiple type annotations are present for the same value
    MultipleTypeAnnotations ValName [SchemeExpr]
  | -- Different pattern lengths have been observed for the same function definition
    DifferentPatternLengths ValName [Int]
  | -- An annotation doesn't have a corresponding definition
    UnimplementedAnnotation ValName
  | -- An error that can occurr while resolving a reference to a type
    SimplifierResolution ResolutionError
  | -- A type variable is not bound in a constructor
    ConstructorUnboundTypeVar ConstructorName TypeVar
  deriving (Eq, Show)

-- An error that can occurr while resolving a reference to a type
data ResolutionError
  = -- A reference to some type that doesn't exist
    UnknownType TypeName
  | -- A mismatch of a type constructor with expected vs actual args
    MismatchedTypeArgs TypeName Int Int
  | -- A type synonym ends up being cyclical
    CyclicalTypeSynonym TypeName [TypeName]
  | -- We tried to lookup a constructor that doesn't exist
    UnknownConstructor ConstructorName
  deriving (Eq, Show)

{- Gathering Type Information -}

-- The information we have about a given constructor
data ConstructorInfo = ConstructorInfo
  { -- The arity i.e. number of arguments that the constructor takes
    --
    -- This information is in the type, but much more convenient to have readily available
    constructorArity :: Int,
    -- The type of this constructor, as a function
    constructorType :: SchemeExpr,
    -- The number this constructor has
    constructorNumber :: Int
  }
  deriving (Eq, Show)

-- A ConstructorMap is a map from constructor names to information about them
type ConstructorMap = Map.Map ConstructorName ConstructorInfo

-- Represents the information we might have when resolving a type name
data ResolvingInformation
  = -- The name is a synonym for a fully resolved expression
    Synonym TypeExpr
  | -- The name is a custom type with a certain arity
    Custom Int
  deriving (Eq, Show)

type ResolutionMap = Map.Map TypeName ResolvingInformation

-- This is a record of all information you might want to have about the types
-- that have been declared in the program.
data TypeInformation = TypeInformation
  { -- A map of all of the type synonyms, fully resolved to a given type
    resolutions :: ResolutionMap,
    -- A map from each constructor's name to the information we have about that constructor
    constructorMap :: ConstructorMap
  }
  deriving (Eq, Show)

-- A class for monadic contexts with access to type information
class Monad m => HasTypeInformation m where
  -- Access the type information available in this context
  typeInformation :: m TypeInformation

-- A class for monadic contexts in which resolution errors can be thrown
class HasTypeInformation m => ResolutionM m where
  throwResolution :: ResolutionError -> m a

resolve :: ResolutionMap -> TypeExpr -> Either ResolutionError TypeExpr
resolve _ IntType = return IntType
resolve _ StringType = return StringType
resolve _ BoolType = return BoolType
resolve _ (TypeVar a) = return (TypeVar a)
resolve mp (t1 :-> t2) = do
  t1' <- resolve mp t1
  t2' <- resolve mp t2
  return (t1' :-> t2')
resolve mp ct@(CustomType name ts) = case Map.lookup name mp of
  Nothing -> Left (UnknownType name)
  Just (Synonym t)
    | null ts -> return t
    | otherwise -> Left (MismatchedTypeArgs name 0 (length ts))
  Just (Custom arity)
    | arity == length ts -> return ct
    | otherwise -> Left (MismatchedTypeArgs name arity (length ts))

-- Resolve a type in a context where we can throw resolution errors, and have access
-- to type information
resolveM :: ResolutionM m => TypeExpr -> m TypeExpr
resolveM expr = do
  resolutions' <- resolutions <$> typeInformation
  either throwResolution return (resolve resolutions' expr)

-- Try and lookup the information about a given constructor, failing with a resolution error
-- if that constructor doesn't exist
lookupConstructor :: ResolutionM m => ConstructorName -> m ConstructorInfo
lookupConstructor name = do
  mp <- constructorMap <$> typeInformation
  let info = Map.lookup name mp
  maybe (throwResolution (UnknownConstructor name)) return info

gatherConstructorMap :: [P.Definition] -> ConstructorMap
gatherConstructorMap =
  foldMap <| \case
    P.TypeDefinition name typeVars definitions ->
      let root = CustomType name (map TypeVar typeVars)
       in foldMap (makeMap typeVars root) (zip definitions [0..])
    _ -> Map.empty
  where
    makeMap :: [TypeVar] -> TypeExpr -> (ConstructorDefinition, Int) -> ConstructorMap
    makeMap typeVars ret (P.ConstructorDefinition cstr types, number) =
      let arity = length types
          scheme = SchemeExpr typeVars (foldr (:->) ret types)
          info = ConstructorInfo arity scheme number
       in Map.singleton cstr info

{- Resolving all of the type synonyms -}

-- Which type definitions does this type reference?
typeDependencies :: TypeExpr -> [TypeName]
typeDependencies StringType = []
typeDependencies IntType = []
typeDependencies BoolType = []
typeDependencies (TypeVar _) = []
typeDependencies (t1 :-> t2) = typeDependencies t1 ++ typeDependencies t2
typeDependencies (CustomType name exprs) = name : concatMap typeDependencies exprs

-- This is the state we keep track of while sorting the graph of types
data SorterState = SorterState
  { -- All of the type names we haven't seen yet
    unseen :: Set.Set TypeName,
    -- The current output we've generated so far
    output :: [TypeName]
  }

-- The context in which the topological sorting of the type graph takes place
--
-- We have access to a set of ancestors to keep track of cycles, the current state,
-- which we can modify, and the ability to throw exceptions.
type SorterM a = ReaderT (Set.Set TypeName) (StateT SorterState (Except ResolutionError)) a

-- Given a mapping from names to shallow types, find a linear ordering of these types
--
-- The types are sorted topologically, based on their dependencies. This means that
-- a type will come after all of its dependencies
sortTypeSynonyms :: Map.Map TypeName TypeExpr -> Either ResolutionError [TypeName]
sortTypeSynonyms mp = runSorter sort (SorterState (Map.keysSet mp) []) |> fmap reverse
  where
    -- Find the dependencies of a given type name
    --
    -- This acts similarly to a "neighbors" function in a traditional graph
    deps :: TypeName -> [TypeName]
    deps k = Map.findWithDefault [] k (Map.map typeDependencies mp)

    -- Run the sorter, given a seed state
    runSorter :: SorterM a -> SorterState -> Either ResolutionError a
    runSorter m st =
      runReaderT m Set.empty |> (`runStateT` st) |> runExcept |> fmap fst

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

-- Gather all of the custom types, along with the number of arguments they contain
gatherCustomTypes :: [P.Definition] -> Map.Map TypeName Int
gatherCustomTypes =
  foldMap <| \case
    P.TypeDefinition name vars _ -> Map.singleton name (length vars)
    _ -> Map.empty

-- Gather all of the type synonyms, at a superficial level
--
-- This will only look at one level of definition, and won't act recursively
gatherTypeSynonyms :: [P.Definition] -> Map.Map TypeName TypeExpr
gatherTypeSynonyms =
  foldMap <| \case
    P.TypeSynonym name expr -> Map.singleton name expr
    _ -> Map.empty

type MakeResolutionM a = ReaderT (Map.Map TypeName TypeExpr) (StateT ResolutionMap (Except ResolutionError)) a

gatherResolutions :: [P.Definition] -> Either ResolutionError ResolutionMap
gatherResolutions defs = do
  let customInfo = gatherCustomTypes defs
      typeSynMap = gatherTypeSynonyms defs
  names <- sortTypeSynonyms typeSynMap
  runResolutionM (resolveAll names) typeSynMap (Map.map Custom customInfo)
  where
    runResolutionM :: MakeResolutionM a -> Map.Map TypeName TypeExpr -> ResolutionMap -> Either ResolutionError ResolutionMap
    runResolutionM m typeSynMap st =
      runReaderT m typeSynMap |> (`execStateT` st) |> runExcept

    resolveAll :: [TypeName] -> MakeResolutionM ()
    resolveAll =
      mapM_ <| \n -> do
        lookup' <- asks (Map.lookup n)
        case lookup' of
          Nothing -> throwError (UnknownType n)
          Just unresolved -> do
            resolutions' <- get
            resolved <- liftEither (resolve resolutions' unresolved)
            modify' (Map.insert n (Synonym resolved))

-- Gather all of the type information we need from the parsed definitions
gatherTypeInformation :: [P.Definition] -> Either SimplifierError TypeInformation
gatherTypeInformation defs = do
  resolutions' <- mapLeft SimplifierResolution <| gatherResolutions defs
  let constructorMap' = gatherConstructorMap defs
  return (TypeInformation resolutions' constructorMap')

{- Converting the actual AST and Expression Tree -}

convertExpr :: P.Expr -> Either SimplifierError (Expr ())
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
        [ (LitteralPattern (BoolLitteral True), thenn'),
          (LitteralPattern (BoolLitteral False), elsse')
        ]
    )
convertExpr (P.NameExpr name) = Right (NameExpr name)
convertExpr (P.LittExpr litt) = Right (LittExpr litt)
convertExpr (P.LambdaExpr names body) = do
  body' <- convertExpr body
  return (foldr (`LambdaExpr` ()) body' names)
convertExpr (P.ApplyExpr f exprs) = do
  f' <- convertExpr f
  exprs' <- traverse convertExpr exprs
  return (foldl' ApplyExpr f' exprs')
convertExpr (P.CaseExpr expr patterns) = do
  expr' <- convertExpr expr
  matrix <- Matrix <$> traverse (\(p, e) -> Row [p] <$> convertExpr e) patterns
  -- We're guaranteed to have a single name, because we have a single column
  let ([name], caseExpr) = compileMatrix matrix
  return (subst name expr' caseExpr)
convertExpr (P.LetExpr defs e) = do
  defs' <- convertValueDefinitions defs
  e' <- convertExpr e
  return (LetExpr defs' e')

-- This converts value definitions by gathering the different patterns into a single lambda expression,
-- and adding the optional type annotation if it exists.
-- This will emit errors if any discrepencies are encountered.
convertValueDefinitions :: [P.ValueDefinition] -> Either SimplifierError [ValueDefinition ()]
convertValueDefinitions =
  groupBy ((==) `on` getName) >>> traverse gather
  where
    getTypeAnnotations :: [P.ValueDefinition] -> [TypeExpr]
    getTypeAnnotations ls =
      (catMaybes <<< (`map` ls)) <| \case
        P.TypeAnnotation _ typ -> Just typ
        _ -> Nothing

    squashPatterns :: [P.ValueDefinition] -> Either SimplifierError (Matrix (Expr ()))
    squashPatterns ls = do
      let strip (P.NameDefinition _ pats body) = do
            body' <- convertExpr body
            return (Just (Row pats body'))
          strip _ = return Nothing
      stripped <- traverse strip ls
      let rows = catMaybes stripped
      return (Matrix rows)

    getName :: P.ValueDefinition -> Name
    getName (P.TypeAnnotation name _) = name
    getName (P.NameDefinition name _ _) = name

    gather :: [P.ValueDefinition] -> Either SimplifierError (ValueDefinition ())
    gather [] = error "groupBy returned empty list"
    gather information = do
      let name = getName (head information)
          annotations = getTypeAnnotations information
      schemeExpr <- case map closeTypeExpr annotations of
        [] -> Right Nothing
        [single] -> Right (Just single)
        tooMany -> Left (MultipleTypeAnnotations name tooMany)
      matrix <- squashPatterns information
      validateMatrix matrix
      let (names, caseExpr) = compileMatrix matrix
          expr = foldr (`LambdaExpr` ()) caseExpr names
      return (ValueDefinition name schemeExpr () expr)

{- Pattern Matching Simplifying -}

-- Check that a pattern is not a wildcard
notWildcard :: P.Pattern -> Bool
notWildcard P.WildcardPattern = False
notWildcard _ = True

swap :: Int -> [a] -> [a]
swap i xs = (xs !! i) : (zip [0 ..] xs |> filter ((/= i) . fst) |> map snd)

-- This is a matrix of patterns, the representation of some match expression
--
-- This matrix might have multiple columns, as generated by a function
-- definition.
newtype Matrix a = Matrix [Row a] deriving (Eq, Show)

validateMatrix :: Matrix a -> Either SimplifierError ()
validateMatrix _ = return ()

-- Represents a row in our pattern matrix
data Row a = Row
  { -- The patterns contained in this row
    rowPats :: [P.Pattern],
    -- The value contained in this row
    rowVal :: a
  }
  deriving (Eq, Show)

allWildCards :: Row a -> Bool
allWildCards = rowPats >>> all (== P.WildcardPattern)

gatherBranches :: [P.Pattern] -> [Branch]
gatherBranches = foldMap pluckHead >>> Set.toList
  where
    pluckHead :: P.Pattern -> Set.Set Branch
    pluckHead (P.LitteralPattern l) =
      Set.singleton (LitteralBranch l)
    pluckHead (P.ConstructorPattern name pats) =
      Set.singleton (ConstructorBranch name (length pats))
    pluckHead _ = Set.empty

-- Get all the columns of a matrix
columns :: Matrix a -> [[P.Pattern]]
columns (Matrix rows) = rows |> map rowPats |> transpose

-- Select the index of the next column in the matrix
nextColumn :: Matrix a -> Maybe Int
nextColumn = columns >>> map (any notWildcard) >>> elemIndex True

-- Swap the nth column of a matrix with the first column
swapColumn :: Int -> Matrix a -> Matrix a
swapColumn index (Matrix rows) =
  let vals = map rowVal rows
      pats = map rowPats rows
      transformed = pats |> transpose |> swap index |> transpose
   in Matrix (zipWith Row transformed vals)

-- Find the first name present in the first column of a matrix
firstName :: Matrix a -> Maybe String
firstName (Matrix rows) = map stripName rows |> asum
  where
    stripName :: Row a -> Maybe String
    stripName (Row (P.NamePattern n : _) _) = Just n
    stripName _ = Nothing

-- Calculate the resulting matrix after choosing the default branch
defaultMatrix :: Matrix a -> Matrix a
defaultMatrix (Matrix rows) =
  rows |> filter isDefault |> map stripHead |> Matrix
  where
    isDefault :: Row a -> Bool
    isDefault (Row [] _) = True
    isDefault (Row (P.WildcardPattern : _) _) = True
    isDefault (Row (P.NamePattern _ : _) _) = True
    isDefault _ = False

    stripHead :: Row a -> Row a
    stripHead (Row pats a) = Row (tail pats) a

-- Calculate the matrix resulting after taking a branch
branchMatrix :: Branch -> Matrix a -> Matrix a
branchMatrix branch (Matrix rows) =
  rows |> map (\(Row pats a) -> (`Row` a) <$> newPats pats) |> catMaybes |> Matrix
  where
    matches :: Branch -> P.Pattern -> Maybe [P.Pattern]
    matches (LitteralBranch l) (P.LitteralPattern l') | l == l' = Just []
    matches (ConstructorBranch name _) (P.ConstructorPattern name' pats)
      | name == name' =
        Just pats
    matches _ _ = Nothing

    makeWildCards :: Branch -> [P.Pattern]
    makeWildCards (LitteralBranch _) = []
    makeWildCards (ConstructorBranch _ arity) = replicate arity P.WildcardPattern

    newPats :: [P.Pattern] -> Maybe [P.Pattern]
    newPats [] = Just []
    newPats (P.WildcardPattern : rest) =
      Just (makeWildCards branch ++ rest)
    newPats (P.NamePattern _ : rest) =
      Just (makeWildCards branch ++ rest)
    newPats (pat : rest) = (++ rest) <$> matches branch pat

-- Represents a decision tree we use to generate a case expression.
--
-- The idea is that the tree represents an imperative set of commands we can
-- use to advance our matches against some expressions.
data Tree a
  = -- Represents a failure in our pattern matching process
    Fail
  | -- Represents the output of a value
    Leaf a
  | -- Swapping the current value in index `i` with the first value, then continue
    Swap Int (Tree a)
  | -- Replace all occurences of a given name with the first value's name, and continue
    SubstOut Name (Tree a)
  | -- Here we have the actual branching
    --
    -- Each of these is a distinct possibility, based on the first value.
    -- The last item is the default branch.
    Select [(Branch, Tree a)] (Tree a)
  deriving (Eq, Show)

-- Represents a type of branch we can take in our decision tree
data Branch
  = -- A branch for a constructor of a certain arity
    ConstructorBranch ConstructorName Int
  | -- A branch for a value of literal type
    LitteralBranch Litteral
  deriving (Eq, Ord, Show)

-- Build up a decision tree from a pattern matrix
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

newtype TreeM a = TreeM (State Int a)
  deriving (Functor, Applicative, Monad, MonadState Int)

runTreeM :: TreeM a -> a
runTreeM (TreeM m) = runState m 0 |> fst

-- Create a fresh name in the Tree folding context
fresh :: TreeM ValName
fresh = do
  c <- get
  put (c + 1)
  return ("$" ++ show c)

-- Fold down a decision tree yielding expressions into a final case expression
--
-- We need to know the number of initial values we're matching against,
-- and have access to the context in which we fold down trees.
foldTree :: Int -> Tree (Expr t) -> TreeM ([ValName], Expr t)
foldTree patCount theTree = do
  names <- replicateM patCount fresh
  expr <- go names theTree
  return (names, expr)
  where
    handleBranch :: [String] -> (Branch, Tree (Expr t)) -> TreeM (Pattern, Expr t)
    handleBranch names (branch, tree) = case branch of
      LitteralBranch l -> (LitteralPattern l,) <$> go names tree
      ConstructorBranch cstr arity -> do
        newNames <- replicateM arity fresh
        expr <- go (newNames ++ names) tree
        return (ConstructorPattern cstr newNames, expr)

    go :: [ValName] -> Tree (Expr t) -> TreeM (Expr t)
    go names tree = case tree of
      Fail -> return (Error "Pattern Match Failure")
      Leaf expr -> return expr
      Swap i tree' -> go (swap i names) tree'
      SubstOut old tree' -> subst old (NameExpr (head names)) <$> go names tree'
      Select branches default' -> do
        let rest = tail names
            scrut = NameExpr (head names)
        branchCases <- traverse (handleBranch rest) branches
        defaultExpr <- go rest default'
        return <| case branchCases of
          [] -> defaultExpr
          _ -> CaseExpr scrut (branchCases ++ [(Wildcard, defaultExpr)])

compileMatrix :: Matrix (Expr t) -> ([ValName], Expr t)
compileMatrix mat@(Matrix rows) =
  let patCount = length (rowPats (head rows))
   in buildTree mat |> foldTree patCount |> runTreeM

{- Glueing it all together -}

convertDefinitions :: [P.Definition] -> Either SimplifierError [ValueDefinition ()]
convertDefinitions = map pluckValueDefinition >>> catMaybes >>> convertValueDefinitions
  where
    pluckValueDefinition :: P.Definition -> Maybe P.ValueDefinition
    pluckValueDefinition (P.ValueDefinition v) = Just v
    pluckValueDefinition _ = Nothing

simplifier :: P.AST -> Either SimplifierError (AST ())
simplifier (P.AST defs) = do
  info <- gatherTypeInformation defs
  defs' <- convertDefinitions defs
  return (AST info defs')
