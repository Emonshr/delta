{-# LANGUAGE OverloadedStrings #-}

module Utils.FormatIdent
  ( formatIdent
  , formatVarIdent
  , formatTypeIdent
  , formatTypeVarIdent
  , formatModuleIdent
  )
where

import qualified Delta.Structures.Syntax as Stx

import Data.Text (Text, intercalate, pack)

formatUpperLetter :: Stx.Letter -> Char
formatUpperLetter c = toEnum $ fromEnum 'A' + fromEnum c

formatLowerLetter :: Stx.Letter -> Char
formatLowerLetter c = toEnum $ fromEnum 'a' + fromEnum c

formatIdentStartChar :: Stx.IdentStartChar -> Char
formatIdentStartChar (Stx.Alpha Stx.LowerCase c) = formatLowerLetter c
formatIdentStartChar (Stx.Alpha Stx.UpperCase c) = formatUpperLetter c
formatIdentStartChar Stx.Underscore = '_'

formatIdentChar :: Stx.IdentChar -> Char
formatIdentChar (Stx.StartChar c) = formatIdentStartChar c
formatIdentChar (Stx.Digit c) = toEnum $ fromEnum '0' + fromEnum c

formatIdent' :: Stx.Ident -> String
formatIdent' (Stx.Ident c cs) = formatIdentStartChar c : map formatIdentChar cs

formatIdent :: Stx.Ident -> Text
formatIdent = pack . formatIdent'

formatIdentTail :: Stx.VarIdentTail -> [Text]
formatIdentTail Stx.EmptyTail = []
formatIdentTail (Stx.TailWord word rest) = " " : Stx.unwrapIdentText word : formatIdentTail rest
formatIdentTail (Stx.TailSlot rest) = " ()" : formatIdentTail rest

formatIdentBody :: Stx.VarIdentBody -> [Text]
formatIdentBody (Stx.BodyWord word rest) = " " : Stx.unwrapIdentText word : formatIdentBody rest
formatIdentBody (Stx.BodySlot rest) = " ()" : formatIdentTail rest

formatVarIdent :: Stx.VarIdent -> Text

formatVarIdent (Stx.VarIdent word rest) =
  intercalate "" $ Stx.unwrapIdentText word : formatIdentBody rest

formatVarIdent (Stx.DotVarIdent word rest) =
  intercalate "" $ "." : Stx.unwrapIdentText word : formatIdentTail rest

formatVarIdent (Stx.OperatorIdent op) =
  case op of
    Stx.OpAdd -> "+"
    Stx.OpSub -> "-"
    Stx.OpMul -> "*"
    Stx.OpDiv -> "/"
    Stx.OpEqu -> "=="
    Stx.OpNotEqu -> "=/="
    Stx.OpGTE -> ">="
    Stx.OpLTE -> "<="
    Stx.OpLT -> "<"
    Stx.OpGT -> ">"
    Stx.OpAnd -> "&&"
    Stx.OpOr -> "||"
    Stx.OpAt -> "@"
    Stx.OpCompLeft -> "<<"
    Stx.OpCompRight -> ">>"

formatVarIdent (Stx.PrefixOperatorIdent op) =
  case op of
    Stx.OpNegate -> "- ()"
    Stx.OpNot -> "~ ()"

formatTypeIdent :: Stx.TypeIdent -> Text
formatTypeIdent (Stx.TypeIdent c cs) =
  pack $ formatUpperLetter c : map formatIdentChar cs

formatTypeVarIdent :: Stx.TypeVarIdent -> Text
formatTypeVarIdent (Stx.TypeVarIdent c cs) = pack $ formatLowerLetter c : map formatIdentChar cs

formatModuleIdent :: Stx.ModuleIdent -> Text
formatModuleIdent (Stx.ModuleIdent c cs) =
  pack $ formatUpperLetter c : map formatIdentChar cs
