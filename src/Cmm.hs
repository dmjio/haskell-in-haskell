{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}

-- | This module contains the intermediate code generator between STG and C
--
-- The reason this exists is primarily to simplify code generation. You could
-- generate C directly from STG, but this leads to more complicated code.
-- The primary mixing of concerns is that of translating the STG semantics into
-- static information, and ordering that information into actual C. For example,
-- all we need to know from a `let` binding is what kind of things get allocated,
-- and how many. If you generate C directly, you mix the calculation of this
-- information with its usage to generate C code. By separating these two parts,
-- you make both of them much simpler.
--
-- Having a separate stage makes it much easier to generate better C code, since
-- you can easily translate the STG into simple imperative statements, and then
-- analyze those to generate nicer C code.
module Cmm (Cmm (..), cmm) where

import Control.Monad.Reader
import Control.Monad.State
import qualified Data.Map.Strict as Map
import Ourlude
import STG

-- | Represents a name we can give to a function
--
-- The individual pieces of a function may not be unique,
-- but if we look at the nested tree of functions and their
-- subfunctions, then we get unique paths.
data FunctionName
  = -- | A standard function name
    StringFunction String
  | -- | A name we can use for the alternatives inside of a function
    Alts
  | -- | A name we use for the entry function
    Entry
  deriving (Show)

type Index = Int

-- | Represents what type of storage some variable will need
--
-- We can figure this out the first time a variable is used, and then
-- use that information in nested closures to figure out how they're going
-- to access this variable that they've captured
data Storage
  = -- | This variable will be stored in a pointer
    PointerStorage
  | -- | This variable will be stored as an int, with 64 bits
    IntStorage
  | -- | This variable will be stored as a string
    StringStorage
  | -- | This variable is a global function with a certain index
    --
    -- When a variable references a global function, we don't need
    -- to store it alongside the closure, since it can just reference it
    -- directly
    GlobalStorage Index
  deriving (Show)

-- | A location allows us to reference some value concretely
data Location
  = -- | This variable is the nth pointer arg passed to us on the stack
    Arg Index
  | -- | This variable is the nth pointer bound in this closure
    Bound Index
  | -- | This variable is the nth int bound in this closure
    BoundInt Index
  | -- | This variable is the nth string bound in this closure
    BoundString Index
  | -- | This variable is just a global function
    Global Index
  | -- | This variable is a closure we've allocated, using an index to figure out which
    Allocated Index
  | -- | This variable is the nth dead pointer
    --
    -- Buried locations come from the bound names used inside the branches of a
    -- case expression. Since we split cases into two, we need a way to save
    -- and restore this before getting back to the case.
    Buried Index
  | -- | The nth dead int. See `Buried` for more information.
    BuriedInt Index
  | -- | The nth dead string. See `Buried` for more information.
    BuriedString Index
  deriving (Show)

-- | Represents a kind of builtin taking two arguments
data Builtin2
  = -- | IntR <- a + b
    Add2
  | -- | IntR <- a - b
    Sub2
  | -- | IntR <- a * b
    Mul2
  | -- | IntR <- a / b
    Div2
  | -- | IntR <- a < b
    Less2
  | -- | IntR <- a <= b
    LessEqual2
  | -- | IntR <- a > b
    Greater2
  | -- | IntR <- a >= b
    GreaterEqual2
  | -- | IntR <- a == b
    EqualTo2
  | -- | IntR <- a /= b
    NotEqualTo2
  | -- | StringR <- a ++ b
    Concat2
  deriving (Show)

-- | Represents a builtin taking only a single argument
data Builtin1
  = -- | Print out an int
    PrintInt1
  | -- | Print out a string
    PrintString1
  | -- | IntR <- -a
    Negate1
  deriving (Show)

-- | Represents a single instruction in our IR
--
-- The idea is that each of these instructions is a little unit that makes
-- sense on the weird VM you need for lazy execution, and also translates
-- directly to a simple bit of C.
data Instruction
  = -- | Store a given integer into the integer register
    StoreInt Int
  | -- | Store a given string litteral into the string register
    StoreString String
  | -- | Store a given tag into the tag register
    StoreTag Tag
  | -- | Enter the code stored at a given location
    --
    -- For this to be valid, that location needs to actually contain *code*,
    -- of course. `BoundString` would not be a valid location here, for example.
    Enter Location
  | -- | We need to enter the code for the continuation at the top of the stack
    --
    -- In practice, this stack will contain the code for the branches
    -- of a case expression, and this instruction yields control to
    -- whatever branches need to match on the value we're producing.
    EnterCaseContinuation
  | -- | Print that an error happened
    PrintError String
  | -- | Apply a builtin expecting two locations
    Builtin2 Builtin2 Location Location
  | -- | Apply a builtin expecting a single location
    Builtin1 Builtin1 Location Location
  | -- | Exit the program
    Exit
  | -- | Push a pointer onto the argument stack
    SAPush Location
  | -- | Bury a pointer used in a case expression
    Bury Location
  | -- | Bury an int used in a case expression
    BuryInt Location
  | -- | Bury a string used in a case expression
    BuryString Location
  | -- | Allocate a table for a function
    --
    -- This function is going to be a direct descendant of the function
    -- in which this instruction appears.
    --
    -- The index is used, since we may reference this closure
    AllocTable FunctionName Index
  | -- | Allocate an int on the heap
    AllocInt Location
  | -- | Allocate a string on the heap
    AllocString Location
  deriving (Show)

-- | An allocation records information about how much a given expression will allocate
--
-- This is useful, because for GC purposes, we want to reserve the amount of memory
-- we need at the very start of the function, which makes it easier to not
-- have any stale pointers lying around.
data Allocation = Allocation
  { -- | The number of tables for closures allocated
    tablesAllocated :: Int,
    -- | The number of pointers inside closures allocated
    pointersAllocated :: Int,
    -- | The number of ints inside closures allocated
    intsAllocated :: Int,
    -- | The number of points to strings inside closures allocated
    stringsAllocated :: Int,
    -- | The raw strings that this function allocates
    --
    -- We need to know exactly which strings, becuase how much memory is allocated
    -- depends on the length of the string.
    primitiveStringsAllocated :: [String]
  }
  deriving (Show)

instance Semigroup Allocation where
  Allocation t p i s ps <> Allocation t' p' i' s' ps' =
    Allocation (t + t') (p + p') (i + i') (s + s') (ps <> ps')

instance Monoid Allocation where
  mempty = Allocation 0 0 0 0 []

-- | A body has some instructions, and allocation information
data Body = Body Allocation [Instruction] deriving (Show)

-- | Information we have about the arguments used in some function
--
-- We can use this to represent a couple things, namely what
-- kind of buried arguments a case expression uses, and what bound
-- arguments are used in a closure.
data ArgInfo = ArgInfo
  { -- | How many buried pointers there are
    buriedPointers :: Int,
    -- | How many buried ints there are
    buriedInts :: Int,
    -- | How many buried strings there are
    buriedStrings :: Int
  }
  deriving (Show)

-- | Represents the body of a function.
--
-- This is either some kind of branching, or a normal function bdoy.
data FunctionBody
  = -- | A case branching on an int
    IntCaseBody ArgInfo [(Int, Body)]
  | -- | A case branching on a string
    StringCaseBody ArgInfo [(String, Body)]
  | -- | A case branching on a tag
    TagCaseBody ArgInfo [(Tag, Body)]
  | -- | Represents a normal function body
    NormalBody Body
  deriving (Show)

-- | Represents a function.
--
-- Functions are the units of execution, but have a bunch of "metadata"
-- associated with them, and can also potentially have subfunctions.
data Function = Function
  { -- | The name of the function
    functionName :: FunctionName,
    -- | If an index is present, then this function corresponds to a certain global index
    --
    -- We do things this way, that way we can traverse the function tree to build up
    -- a table of index functions to fully resolved function names. Trying
    -- to generate the fully resolved function name at this stage would be annoying.
    isGlobal :: Maybe Index,
    -- | Information about the number of pointer arguments
    --
    -- Since primitives can't be passed to functions, this just the number of pointers
    argCount :: Int,
    -- | Information about the number of bound arguments
    --
    -- This also tells us how to garbage collect the closure, along with the information
    -- about whether or not this function is global.
    boundArgs :: ArgInfo,
    -- | The actual body of this function
    body :: FunctionBody,
    -- | The functions defined nested inside of this function
    subFunctions :: [Function]
  }
  deriving (Show)

-- | A bit of CMM ast is nothing more than a list of functions, and an entry function
data Cmm = Cmm [Function] Function deriving (Show)

-- | Represents the context we use when generating Cmm
data Context = Context
  { -- | A map from names to their corresponding storages
    storages :: Map.Map ValName Storage
  }
  deriving (Show)

-- | A default context to start with
startingContext :: Context
startingContext = Context mempty

-- | A computation in which we have access to this context, and can make fresh variables
newtype ContextM a = ContextM (ReaderT Context (State Int) a)
  deriving (Functor, Applicative, Monad, MonadReader Context, MonadState Int)

-- | Run a contextful computation
runContextM :: ContextM a -> a
runContextM (ContextM m) = m |> (`runReaderT` startingContext) |> (`runState` 0) |> fst

-- | Generate a fresh index, that hasn't been used before
fresh :: ContextM Index
fresh = do
  current <- get
  modify' (+ 1)
  return current

withStorages :: [(ValName, Storage)] -> ContextM a -> ContextM a
withStorages newStorages = local (\r -> r {storages = Map.fromList newStorages <> storages r})

-- | Get the storage of a given name
--
-- We set things up so that a name always has a storage before we ask for it,
-- because of this, it's an *implementation error* if we can't find the storage for a name.
getStorage :: ValName -> ContextM Storage
getStorage name = asks (storages >>> Map.findWithDefault err name)
  where
    err = error ("No storage found for: " <> show name)

genLamdbdaForm :: FunctionName -> Maybe Index -> LambdaForm -> ContextM Function
genLamdbdaForm functionName isGlobal _ =
  let argCount = 0
      boundArgs = ArgInfo 0 0 0
      body = NormalBody (Body mempty [])
      subFunctions = []
   in return Function {..}

genBinding :: Binding -> ContextM Function
genBinding (Binding name form) = do
  storage <- getStorage name
  let isGlobal' = case storage of
        GlobalStorage index -> Just index
        _ -> Nothing
  genLamdbdaForm (StringFunction name) isGlobal' form

-- | Generate Cmm code from STG, in a contextful way
genCmm :: STG -> ContextM Cmm
genCmm (STG bindings entryForm) = do
  entryIndex <- fresh
  topLevelStorages <-
    forM bindings <| \(Binding name _) -> do
      index <- fresh
      return (name, GlobalStorage index)
  withStorages topLevelStorages <| do
    entry <- genLamdbdaForm Entry (Just entryIndex) entryForm
    topLevel <- forM bindings genBinding
    return (Cmm topLevel entry)

-- | Generate Cmm code from STG
cmm :: STG -> Cmm
cmm = genCmm >>> runContextM