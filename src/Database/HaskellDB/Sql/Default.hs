-----------------------------------------------------------
-- |
-- Module      :  Database.HaskellDB.Sql.Default
-- Copyright   :  Daan Leijen (c) 1999, daan@cs.uu.nl
--                HWT Group (c) 2003, haskelldb-users@lists.sourceforge.net
-- License     :  BSD-style
-- 
-- Maintainer  :  haskelldb-users@lists.sourceforge.net
-- Stability   :  experimental
-- Portability :  non-portable
-- 
-- Default SQL generation.
-- 
-----------------------------------------------------------
module Database.HaskellDB.Sql.Default (
                                        mkSqlGenerator,
                                        defaultSqlGenerator,

                                        defaultSqlQuery,
                                        defaultSqlUpdate,
                                        defaultSqlDelete,
                                        defaultSqlInsert,
                                        defaultSqlInsertQuery,
                                        defaultSqlCreateDB,
                                        defaultSqlCreateTable,
                                        defaultSqlDropDB,
                                        defaultSqlDropTable,

                                        defaultSqlEmpty,
                                        defaultSqlTable,
                                        defaultSqlProject,
                                        defaultSqlRestrict,
                                        defaultSqlBinary,
                                        defaultSqlGroup,
                                        defaultSqlSpecial,

                                        defaultSqlExpr,
                                        defaultSqlLiteral,
                                        defaultSqlType,
                                        defaultSqlQuote,

                                        -- * Utilities
                                        toSqlSelect
                                       ) where

import Data.List (intersect)
import Database.HaskellDB.PrimQuery
import Database.HaskellDB.FieldType
import Database.HaskellDB.Sql
import Database.HaskellDB.Sql.Generate

import System.Locale
import System.Time
import Data.Maybe (catMaybes)
import Data.List (nubBy)

mkSqlGenerator :: SqlGenerator -> SqlGenerator
mkSqlGenerator gen = SqlGenerator 
    {
     sqlQuery       = defaultSqlQuery       gen,
     sqlUpdate      = defaultSqlUpdate      gen,
     sqlDelete      = defaultSqlDelete      gen,
     sqlInsert      = defaultSqlInsert      gen,
     sqlInsertQuery = defaultSqlInsertQuery gen,
     sqlCreateDB    = defaultSqlCreateDB    gen,
     sqlCreateTable = defaultSqlCreateTable gen,
     sqlDropDB      = defaultSqlDropDB      gen,
     sqlDropTable   = defaultSqlDropTable   gen,

     sqlEmpty       = defaultSqlEmpty       gen,
     sqlTable       = defaultSqlTable       gen,
     sqlProject     = defaultSqlProject     gen,
     sqlRestrict    = defaultSqlRestrict    gen,
     sqlBinary      = defaultSqlBinary      gen,
     sqlGroup       = defaultSqlGroup       gen,
     sqlSpecial     = defaultSqlSpecial     gen,

     sqlExpr        = defaultSqlExpr        gen,
     sqlLiteral     = defaultSqlLiteral     gen,
     sqlType        = defaultSqlType        gen,
     sqlQuote       = defaultSqlQuote       gen
    }

defaultSqlGenerator :: SqlGenerator
defaultSqlGenerator = mkSqlGenerator defaultSqlGenerator

-----------------------------------------------------------
-- * Types
-----------------------------------------------------------

defaultSqlType :: SqlGenerator -> FieldType -> SqlType
defaultSqlType _ t = 
    case t of
      StringT       -> SqlType "text"
      IntT          -> SqlType "int"
      IntegerT      -> SqlType "bigint"
      DoubleT       -> SqlType "double precision"
      BoolT         -> SqlType "bit"
      CalendarTimeT -> SqlType "timestamp"
      BStrT a       -> SqlType1 "varchar" a

-----------------------------------------------------------
-- * SELECT
-----------------------------------------------------------

-- | Creates a 'SqlSelect' based on the 'PrimQuery' supplied.
-- Corresponds to the SQL statement SELECT.
defaultSqlQuery :: SqlGenerator -> PrimQuery -> SqlSelect
defaultSqlQuery gen query = foldPrimQuery (sqlEmpty gen, 
                                     sqlTable gen,
                                     sqlProject gen,
                                     sqlRestrict gen,
                                     sqlBinary gen,
                                     sqlGroup gen,
                                     sqlSpecial gen) query

defaultSqlEmpty :: SqlGenerator -> SqlSelect
defaultSqlEmpty _ = SqlEmpty

defaultSqlTable :: SqlGenerator -> TableName -> Scheme -> SqlSelect
defaultSqlTable _ name schema = SqlTable name

defaultSqlProject :: SqlGenerator -> Assoc -> SqlSelect -> SqlSelect
defaultSqlProject gen assoc q
          	| hasAggr    = select { groupby = toSqlAssoc gen groupableProjections ++ groupableOrderCols }
          	| otherwise  = select 
                where
                  select   = sql { attrs = toSqlAssoc gen assoc }
                  sql      = toSqlSelect q
                  hasAggr  = not . null  . filter (isAggregate . snd) $ assoc
                  -- Find projected columns that are not constants or aggregates.
                  groupableProjections = filter (not . (\x -> isAggregate x || isConstant x) . snd) assoc
                  -- Get list of order by columns which do not appear in
                  -- projected non-aggregate columns already, if any.
                  groupableOrderCols =
                    let eligible = filter (\x -> case x of
                                              (ColumnSqlExpr attr) ->
                                                  not (attr `elem` groupableAttrs)
                                              _ -> False) .
                              map fst $ orderby sql
                        -- List of non-aggregated columns which are only attribute expressions, i.e.
                        -- aliased columns. 
                        groupableAttrs = [col | (AttrExpr col) <- map snd groupableProjections]
                    in [(s, e) | e@(ColumnSqlExpr s) <- eligible]

-- | Takes all non-aggregate expressions in the select and adds them to
-- the 'group by' clause.
defaultSqlGroup :: SqlGenerator -> Assoc -> SqlSelect -> SqlSelect
defaultSqlGroup gen cols q =
  let selectCols = concat (allCols q) -- List of all columns in order by, group by or 'select' clause in SqlSelect.
      -- Nested search for all valid columns.
      allCols :: SqlSelect -> [[(SqlColumn, SqlExpr)]]
      allCols (SqlSelect { attrs = a, groupby = g, tables = t, orderby = o}) = a : g : toColExpr o : concatMap (allCols . snd) t
      allCols (SqlBin _ l r) = allCols l ++ allCols r
      allCols _ = []
      -- Convert order by expressions to SqlColumn looking expressions.
      -- Luckily, order by never has antyhig but ColumnSqlExpr in it for now.
      toColExpr :: [(SqlExpr,SqlOrder)] -> [(SqlColumn,SqlExpr)]
      toColExpr = 
        let f (ColumnSqlExpr s) = Just (s, undefined)
        in catMaybes . map (f . fst)
      -- Ensure that each column in the groupby actually exists
      -- in the projection. Also converts all expressions
      -- to ColumnSqlExpr so they work correctly in group by.
      mkValidCol (name, expr) =
        case lookup name selectCols of
          Just _ -> Just (name, sqlExpr gen expr)
          Nothing -> Nothing
      select = toSqlSelect q
      groupbys = catMaybes . map mkValidCol $ cols
  in select { groupby = groupbys }


defaultSqlRestrict :: SqlGenerator -> PrimExpr -> SqlSelect -> SqlSelect
defaultSqlRestrict gen expr q
                = sql { criteria = sqlExpr gen expr : criteria sql }
                where
                  sql   = toSqlSelect q

defaultSqlBinary :: SqlGenerator -> RelOp -> SqlSelect -> SqlSelect -> SqlSelect
defaultSqlBinary _ Times q1@(SqlSelect { }) q2@(SqlSelect { }) 
          	| null (attrs q1) = addTable q1 q2
          	| null (attrs q2) = addTable q2 q1
          	| otherwise       = newSelect { tables = [("",q1),("",q2)] }
          	where
          	  addTable sql q  = sql{ tables = tables sql ++ [("",q)] }
defaultSqlBinary _ Times q1 q2 = newSelect { tables = [("", q1), ("", q2)] }
defaultSqlBinary _ op q1 q2         
          	= SqlBin (toSqlOp op) q1 q2

defaultSqlSpecial :: SqlGenerator -> SpecialOp -> SqlSelect -> SqlSelect
defaultSqlSpecial gen (Order o) q
	  	= sql { orderby = newOrder ++ oldOrder }  
		where
		  sql 	    = toSqlSelect q
                  newOrder  = map (toSqlOrder gen) o

		  -- FIXME: what if they conflict?
                  -- The old version tried to fix that, but that
                  -- would only work partly
		  oldOrder  = orderby sql		  	    
defaultSqlSpecial _ (Top n) q
                  -- FIXME: works for a few databases
                  -- maybe we should use ROW_NUMBER() here
          	= sql { extra = ("LIMIT " ++ show n) : extra sql }
          	where sql = toSqlSelect q


toSqlOrder :: SqlGenerator -> OrderExpr -> (SqlExpr,SqlOrder)
toSqlOrder gen (OrderExpr o e) = (sqlExpr gen e, o')
    where o' = case o of
                 OpAsc  -> SqlAsc
                 OpDesc -> SqlDesc

-- | Make sure our SqlSelect statement is really a SqlSelect and not
-- one other constructors.
toSqlSelect :: SqlSelect -> SqlSelect
toSqlSelect sql = case sql of
                    (SqlEmpty)          -> newSelect
                    (SqlTable name)     -> newSelect { tables = [("",sql)] }
                    (SqlBin op q1 q2)   -> newSelect { tables = [("",sql)] }
                    (SqlSelect { groupby = group, attrs = cols, tables = tbls})
                      | null cols && null group -> sql 
                      | null cols && not (null group) ->
                          -- This situation arises when a columns used in a group by are
                          -- not explicitly projected, or only aggregates are.
                          --
                          -- We make the groupby its own "subquery" below which projects
                          -- only "group by" columns, without introducing any aliases. We then
                          -- create a new select which projects the original columns projected by
                          -- the group by (i.e. those in the "tables" slot of the groupby select).
                          --
                          -- This addresses a bug where GROUP BY statements would disappear
                          -- if the query did not use the grouped columns, or the would
                          -- float out of subqueries indirectly.
                          --
                          let removeDups = nubBy (\(c1, _) (c2, _) -> c1 == c2)
                              -- Makes a list of columns pass-through - i.e. projected
                              -- with no aliasing.
                              passThrough = map ((\c -> (c, ColumnSqlExpr c)) . fst)
                              -- List of columns projected by subquery found in tables field.
                              currProj = passThrough $ concatMap (attrs . snd) tbls
                              -- Columns projected due the group by
                              groupProj =  passThrough group
                              newSql = sql { attrs = removeDups $ groupProj ++ currProj }
                          in newSelect { attrs = currProj
                                        , tables = [("", newSql)]}
                      | otherwise -> newSelect { tables = [("",sql)] }
                      

toSqlAssoc :: SqlGenerator -> Assoc -> [(SqlColumn,SqlExpr)]
toSqlAssoc gen = map (\(attr,expr) -> (attr, sqlExpr gen expr))

toSqlOp :: RelOp -> String
toSqlOp Union        = "UNION"
toSqlOp Intersect    = "INTERSECT"
toSqlOp Divide       = "DIVIDE"
toSqlOp Difference   = "EXCEPT"


-----------------------------------------------------------
-- * UPDATE
-----------------------------------------------------------

-- | Creates a 'SqlUpdate'. Corresponds to the SQL statement
-- UPDATE which updates data in a table.
defaultSqlUpdate :: SqlGenerator 
                 -> TableName  -- ^ Name of the table to update.
	         -> [PrimExpr] -- ^ Conditions which must all be true for a row
                               --   to be updated.
                 -> Assoc -- ^ Update the data with this.
	         -> SqlUpdate
defaultSqlUpdate gen name criteria assigns
        = SqlUpdate name (toSqlAssoc gen assigns) (map (sqlExpr gen) criteria) 


-----------------------------------------------------------
-- * INSERT
-----------------------------------------------------------

-- | Creates a 'SqlInsert'. 
defaultSqlInsert :: SqlGenerator 
                 -> TableName -- ^ Name of the table
	         -> Assoc -- ^ What to insert.
	         -> SqlInsert
defaultSqlInsert gen table assoc = SqlInsert table cs es
    where (cs,es) = unzip (toSqlAssoc gen assoc)

-- | Creates a 'SqlInsert'. Corresponds to the SQL statement
-- INSERT INTO which is used to insert new rows in a table.
defaultSqlInsertQuery :: SqlGenerator 
                      -> TableName -- ^ Name of the table
	              -> PrimQuery -- ^ What to insert
	              -> SqlInsert
defaultSqlInsertQuery gen table q = SqlInsertQuery table cs sql
    where cs = attributes q
          sql = sqlQuery gen q


-----------------------------------------------------------
-- * DELETE
-----------------------------------------------------------

-- | Creates a 'SqlDelete'. Corresponds to the SQL statement
-- DELETE which deletes rows in a table.
defaultSqlDelete :: SqlGenerator 
                 -> TableName -- ^ Name of the table
	         -> [PrimExpr] -- ^ Criteria which must all be true for a row
                               --   to be deleted.
	         -> SqlDelete
defaultSqlDelete gen name criteria = SqlDelete name (map (sqlExpr gen) criteria)


-----------------------------------------------------------
-- * CREATE
-----------------------------------------------------------

-- | Use this to create a 'SqlCreate' data type corresponding to 
-- the SQL statement CREATE DATABASE which creates a new database.
defaultSqlCreateDB :: SqlGenerator
                   -> String -- ^ name of the database.
	           -> SqlCreate
defaultSqlCreateDB _ name = SqlCreateDB name

-- | Use this to create a 'SqlCreate' data type corresponding to 
-- the SQL statement CREATE which creates a new table.
defaultSqlCreateTable :: SqlGenerator
                   -> TableName -- ^ name of the table to be created.
	           -> [(Attribute,FieldDesc)] -- ^ Column descriptions
                   -> SqlCreate
defaultSqlCreateTable gen name xs = 
    SqlCreateTable name [(cname, (sqlType gen t,nullable)) 
                             | (cname, (t,nullable)) <- xs]


-----------------------------------------------------------
-- * DROP
-----------------------------------------------------------

-- | Creates a 'SqlDrop' that delete the database with the 
-- name given as the first argument.
defaultSqlDropDB :: SqlGenerator -> String -> SqlDrop
defaultSqlDropDB _ name = SqlDropDB name

-- | Creates a 'SqlDrop' that delete the database named
-- in the first argument.
defaultSqlDropTable :: SqlGenerator -> TableName -> SqlDrop
defaultSqlDropTable _ name = SqlDropTable name


-- * Expressions

defaultSqlExpr :: SqlGenerator -> PrimExpr -> SqlExpr
defaultSqlExpr gen e = 
    case e of
      AttrExpr a       -> ColumnSqlExpr a
      BinExpr op e1 e2 ->
        let leftE = sqlExpr gen e1
            rightE = sqlExpr gen e2
            paren = ParensSqlExpr
            (expL, expR) = case (op, e1, e2) of
              (OpAnd, e1@(BinExpr OpOr _ _), e2@(BinExpr OpOr _ _)) ->
                (paren leftE, paren rightE)
              (OpOr, e1@(BinExpr OpAnd _ _), e2@(BinExpr OpAnd _ _)) ->
                (paren leftE, paren rightE)
              (OpAnd, e1@(BinExpr OpOr _ _), e2) ->
                (paren leftE, rightE)
              (OpAnd, e1, e2@(BinExpr OpOr _ _)) ->
                (leftE, paren rightE)
              (OpOr, e1@(BinExpr OpAnd _ _), e2) ->
                (paren leftE, rightE)
              (OpOr, e1, e2@(BinExpr OpAnd _ _)) ->
                (leftE, paren rightE)
              _ -> (leftE, rightE)
        in BinSqlExpr (showBinOp op) expL expR
      UnExpr op e      -> let (op',t) = sqlUnOp op
                              e' = sqlExpr gen e
                           in case t of
                                UnOpFun     -> FunSqlExpr op' [e']
                                UnOpPrefix  -> PrefixSqlExpr op' e'
                                UnOpPostfix -> PostfixSqlExpr op' e'
      AggrExpr op e    -> let op' = showAggrOp op
                              e' = sqlExpr gen e
                           in FunSqlExpr op' [e']
      ConstExpr l      -> ConstSqlExpr (sqlLiteral gen l)
      CaseExpr cs e    -> let cs' = [(sqlExpr gen c, sqlExpr gen x)| (c,x) <- cs] 
                              e'  = sqlExpr gen e
                           in CaseSqlExpr cs' e'
      ListExpr es      -> ListSqlExpr (map (sqlExpr gen) es)
      ParamExpr n v    -> ParamSqlExpr n PlaceHolderSqlExpr
      FunExpr n exprs  -> FunSqlExpr n (map (sqlExpr gen) exprs)
      CastExpr typ e1 -> CastSqlExpr typ (sqlExpr gen e1)

showBinOp :: BinOp -> String
showBinOp  OpEq         = "=" 
showBinOp  OpLt         = "<" 
showBinOp  OpLtEq       = "<=" 
showBinOp  OpGt         = ">" 
showBinOp  OpGtEq       = ">=" 
showBinOp  OpNotEq      = "<>" 
showBinOp  OpAnd        = "AND"  
showBinOp  OpOr         = "OR" 
showBinOp  OpLike       = "LIKE" 
showBinOp  OpIn         = "IN" 
showBinOp  (OpOther s)  = s
showBinOp  OpCat        = "+" 
showBinOp  OpPlus       = "+" 
showBinOp  OpMinus      = "-" 
showBinOp  OpMul        = "*" 
showBinOp  OpDiv        = "/" 
showBinOp  OpMod        = "MOD" 
showBinOp  OpBitNot     = "~" 
showBinOp  OpBitAnd     = "&" 
showBinOp  OpBitOr      = "|" 
showBinOp  OpBitXor     = "^"
showBinOp  OpAsg        = "="


data UnOpType = UnOpFun | UnOpPrefix | UnOpPostfix

sqlUnOp :: UnOp -> (String,UnOpType)
sqlUnOp  OpNot         = ("NOT", UnOpPrefix)
sqlUnOp  OpIsNull      = ("IS NULL", UnOpPostfix)
sqlUnOp  OpIsNotNull   = ("IS NOT NULL", UnOpPostfix)
sqlUnOp  OpLength      = ("LENGTH", UnOpFun)
sqlUnOp  (UnOpOther s) = (s, UnOpFun)


showAggrOp :: AggrOp -> String
showAggrOp AggrCount    = "COUNT" 
showAggrOp AggrSum      = "SUM" 
showAggrOp AggrAvg      = "AVG" 
showAggrOp AggrMin      = "MIN" 
showAggrOp AggrMax      = "MAX" 
showAggrOp AggrStdDev   = "StdDev" 
showAggrOp AggrStdDevP  = "StdDevP" 
showAggrOp AggrVar      = "Var" 
showAggrOp AggrVarP     = "VarP"                
showAggrOp (AggrOther s)        = s


defaultSqlLiteral :: SqlGenerator -> Literal -> String
defaultSqlLiteral gen l = 
    case l of
      NullLit       -> "NULL"
      DefaultLit    -> "DEFAULT"
      BoolLit True  -> "TRUE"
      BoolLit False -> "FALSE"
      StringLit s   -> quote s
      IntegerLit i  -> show i
      DoubleLit d   -> show d
      DateLit t     -> quote (formatCalendarTime defaultTimeLocale fmt t)
	  where fmt = iso8601DateFormat (Just "%H:%M:%S")
      OtherLit l    -> l


defaultSqlQuote :: SqlGenerator -> String -> String
defaultSqlQuote gen s = quote s

-- | Quote a string and escape characters that need escaping
--   FIXME: this is backend dependent
quote :: String -> String 
quote s = "'" ++ concatMap escape s ++ "'"

-- | Escape characters that need escaping
escape :: Char -> String
escape '\NUL' = "\\0"
escape '\'' = "''"
escape '"' = "\\\""
escape '\b' = "\\b"
escape '\n' = "\\n"
escape '\r' = "\\r"
escape '\t' = "\\t"
escape '\\' = "\\\\"
escape c = [c]

