module ParserTest (tests) where

import Debug.Trace
import Lexer (lexer)
import Ourlude
import Parser (AST (..), BinOp (..), Definition (..), Expr (..), TypeExpr (..), parse)
import Test.Tasty
import Test.Tasty.HUnit

shouldParse :: String -> AST -> Assertion
shouldParse str ast =
  let eitherToMaybe = either (const Nothing) Just
      tokens = lexer str
      result =
        eitherToMaybe tokens >>= \toks ->
          let parsed = parse toks
           in traceShow parsed <| eitherToMaybe parsed
   in traceShow tokens <| Just ast @=? result

tests :: TestTree
tests =
  testGroup
    "Parser Tests"
    [ testCase
        "parsing basic definitions"
        ( shouldParse
            "{ x :: Int; x = 3 }"
            (AST [TypeDefinition "x" IntType, Definition "x" (IntExpr 3)])
        ),
      testCase
        "parsing let definitions"
        ( shouldParse
            "x = \n  let\n    y = 3\n  in y"
            (AST [Definition "x" (LetExpr [Definition "y" (IntExpr 3)] (NameExpr "y"))])
        ),
      testCase
        "parsing where definitions"
        ( shouldParse
            "x = y where y = 3"
            (AST [Definition "x" (WhereExpr (NameExpr "y") [Definition "y" (IntExpr 3)])])
        ),
      testCase
        "parsing binary expressions"
        ( shouldParse
            "x = a + f a * a / a - a ++ a"
            ( AST
                [ Definition
                    "x"
                    ( BinExpr
                        Concat
                        ( BinExpr
                            Sub
                            ( BinExpr
                                Add
                                (NameExpr "a")
                                ( BinExpr
                                    Div
                                    ( BinExpr
                                        Mul
                                        (ApplyExpr (NameExpr "f") [(NameExpr "a")])
                                        (NameExpr "a")
                                    )
                                    (NameExpr "a")
                                )
                            )
                            (NameExpr "a")
                        )
                        (NameExpr "a")
                    )
                ]
            )
        )
    ]