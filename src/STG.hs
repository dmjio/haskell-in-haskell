{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}

module STG (STG (..), Atom (..), Litteral (..), ValName, stg) where

import Control.Monad (mapM)
import Control.Monad.State
import Ourlude
import Simplifier
  ( AST (..),
    Builtin (..),
    ConstructorName,
    Litteral (..),
    SchemeExpr (..),
    ValName,
    ValueDefinition (..),
    pickValueDefinitions,
  )
import qualified Simplifier as S

-- Represents a unit of data simple enough to be passed directly
--
-- With STG, we want to limit the complexity of expressions that appear
-- inside other applications, to make compilation much easier.
data Atom
  = -- A litteral value
    LitteralAtom Litteral
  | -- A reference to a name
    NameAtom ValName
  deriving (Eq, Show)

-- Represents a tag for an alternative of an algebraic data type
type Tag = Int

-- Represents an expression in our STG language
data Expr
  = -- A litteral value
    Litteral Litteral
  | -- Apply a name (function) to a potentially empty sequence of atoms
    Apply ValName [Atom]
  | -- Panic with a given error
    --
    -- This is something we introduce here, to be able to provide an expression
    -- for the default branch of a case
    Error String
  | -- Apply an ADT constructor to a sequence of atoms
    --
    -- The constructor must be fully saturated, i.e. its arity
    -- should match the number of atoms here.
    Constructor Tag [Atom]
  | -- Apply a fully saturated builtin to a given sequence of atoms
    Builtin Builtin [Atom]
  | -- Inspect an expression, and handle the different cases.
    --
    -- We don't take an atom here, because building up a thunk we
    -- immediately evaluate would be a bit pointless
    Case Expr Alts
  | -- A series of bidnings appearing before an expression
    Let [Binding] Expr
  deriving (Eq, Show)

-- Represents different branches of shallow alternatives.
--
-- As opposed to patterns, alternatives only look at a single level
-- of data.
--
-- Alternatives always have a default expression.
--
-- We split alternatives for different litterals, mainly to simplify
-- code generation. If we used a single alternative for all litterals,
-- we'd lose information about what types are involved, making code
-- generation more cumbersome
data Alts
  = -- Potential branches for integer litterals, then a default expression
    IntAlts [(Int, Expr)] DefaultAlt
  | -- Potential branches for booleans, then a default expression
    --
    -- Because booleans only have two values, we could simplify this representation,
    -- but that would make generating STG harder, and whatever compiler
    -- for the low level IR we generate should be able to see the redundancy.
    BoolAlts [(Bool, Expr)] DefaultAlt
  | -- Potential branches for string litterals, then a default case
    StringAlts [(String, Expr)] DefaultAlt
  | -- Potential branches for constructor tags, introducing names,
    -- and then we end, as usual, with a default case
    ConstrAlts [(Tag, [ConstructorName], Expr)] DefaultAlt
  deriving (Eq, Show)

-- A default alternative, which may introduce a variable, or not
data DefaultAlt
  = -- A wildcard alternative, introducing no variables
    WildCard Expr
  | -- A variable alternative, introducing a single variable
    VarAlt ValName Expr
  deriving (Eq, Show)

-- A flag telling us when a thunk is updateable
--
-- By default, all thunks are updateable, and marking thunks
-- as non-updateable is an optimization for certain thinks
-- which we know to already be fully evaluated, or which aren't
-- used more than once.
data Updateable = N | U deriving (Eq, Show)

-- Represents a lambda expression
--
-- We first have a list of free variables occurring in the body,
-- the updateable flag, then the list of parameters, and then the body
data LambdaForm = LambdaForm [ValName] Updateable [ValName] Expr deriving (Eq, Show)

-- Represents a binding from a name to a lambda form
--
-- In STG, bindings always go through lambda forms, representing
-- the connection with heap allocated thunks.
data Binding = Binding ValName LambdaForm deriving (Eq, Show)

-- Represents an STG program, which is just a list of top level bindings.
newtype STG = STG [Binding] deriving (Eq, Show)

-- The Context in which we generate STG code
--
-- We have access to a source of fresh variable names.
newtype STGM a = STGM (State Int a)
  deriving (Functor, Applicative, Monad, MonadState Int)

runSTGM :: STGM a -> a
runSTGM (STGM m) = runState m 0 |> fst

-- Create a fresh name
fresh :: STGM ValName
fresh = do
  x <- get
  put (x + 1)
  return ("$$" ++ show x)

gatherApplications :: S.Expr SchemeExpr -> (S.Expr SchemeExpr, [S.Expr SchemeExpr])
gatherApplications expression = go expression []
  where
    go (S.ApplyExpr f e) acc = go f (e : acc)
    go e acc = (e, acc)

atomize :: S.Expr SchemeExpr -> STGM ([Binding], Atom)
atomize expression = case expression of
  S.LittExpr l -> return ([], LitteralAtom l)
  S.NameExpr n -> return ([], NameAtom n)
  e -> do
    name <- fresh
    l <- exprToLambda e
    return ([Binding name l], NameAtom name)

atomToExpr :: Atom -> Expr
atomToExpr (LitteralAtom l) = Litteral l
atomToExpr (NameAtom n) = Apply n []

makeLet :: [Binding] -> Expr -> Expr
makeLet [] e = e
makeLet bindings e = Let bindings e

-- Convert an expression into an STG expression
convertExpr :: S.Expr SchemeExpr -> STGM Expr
convertExpr =
  gatherApplications >>> \case
    (e, []) -> handle e
    (f, args) -> case f of
      -- Builtins, which are all operators, will be fully saturated from a parsing perspective
      S.Builtin b -> do
        (bindings, atoms) <- gatherAtoms args
        return (makeLet bindings (Builtin b atoms))
      S.NameExpr n -> do
        (bindings, atoms) <- gatherAtoms args
        return (makeLet bindings (Apply n atoms))
      e -> do
        (argBindings, atoms) <- gatherAtoms args
        (eBindings, atom) <- atomize e
        return <| case atom of
          LitteralAtom _ -> error "Litterals cannot be functions"
          NameAtom n -> makeLet (argBindings ++ eBindings) (Apply n atoms)
  where
    handle :: S.Expr SchemeExpr -> STGM Expr
    handle (S.LittExpr l) = return (Litteral l)
    handle (S.NameExpr n) = return (Apply n [])
    handle (S.LetExpr defs e) = do
      defs' <- convertValueDefinitions defs
      e' <- convertExpr e
      return (makeLet defs' e')
    handle lambda@S.LambdaExpr {} = do
      (bindings, atom) <- atomize lambda
      return (makeLet bindings (atomToExpr atom))
    handle S.ApplyExpr {} = error "Apply Expressions shouldn't appear here"
    handle S.Builtin {} = error "Unary builtin operation"
    handle S.CaseExpr {} = undefined

    gatherAtoms :: [S.Expr SchemeExpr] -> STGM ([Binding], [Atom])
    gatherAtoms = mapM atomize >>> fmap gatherBindings

    gatherBindings :: [([b], a)] -> ([b], [a])
    gatherBindings l = (concatMap fst l, map snd l)

-- Convert an expression to a lambda form
--
-- This will always create a lambda, although with no
-- arguments if the expression we're converting wasn't
-- a lambda to begin with
exprToLambda :: S.Expr SchemeExpr -> STGM LambdaForm
exprToLambda =
  gatherLambdas
    >>> \(names, e) -> LambdaForm [] U names <$> convertExpr e
  where
    gatherLambdas :: S.Expr SchemeExpr -> ([ValName], S.Expr SchemeExpr)
    gatherLambdas (S.LambdaExpr name _ e) =
      let (names, e') = gatherLambdas e
       in (name : names, e')
    gatherLambdas e = ([], e)

-- Convert a definition into an STG binding
convertDef :: ValueDefinition SchemeExpr -> STGM Binding
convertDef (NameDefinition name _ _ e) =
  Binding name <$> exprToLambda e

-- Convert the value definitions composing a program into STG
convertValueDefinitions :: [ValueDefinition SchemeExpr] -> STGM [Binding]
convertValueDefinitions = mapM convertDef

convertAST :: AST SchemeExpr -> STGM STG
convertAST (AST defs) =
  defs |> pickValueDefinitions |> convertValueDefinitions |> fmap STG

-- Run the STG compilation step
stg :: AST SchemeExpr -> STG
stg = convertAST >>> runSTGM