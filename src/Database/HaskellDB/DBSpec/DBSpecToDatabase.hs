-----------------------------------------------------------
-- |
-- Module      :  DBSpecToDatabase
-- Copyright   :  HWT Group (c) 2004, dp03-7@mdstud.chalmers.se
-- License     :  BSD-style
-- 
-- Maintainer  :  dp03-7@mdstud.chalmers.se
-- Stability   :  experimental
-- Portability :  non-portable
--
-- Connects to a database and generates stuff in it according
-- to what's inside the DBSpec
-----------------------------------------------------------
module Database.HaskellDB.DBSpec.DBSpecToDatabase 
    (dbSpecToDatabase)
    where

import Database.HaskellDB.Database
import Database.HaskellDB.DBSpec.DBInfo

-- | Converts a DBInfo to a real life Database, note that the database must
-- exist for this to work
dbSpecToDatabase :: Database -- ^ A Database
		 -> DBInfo -- ^ The DBInfo to generate from
		 -> IO ()
dbSpecToDatabase db dbi
    = mapM_ (\t -> createTable db (tname t) (createAttFD t)) (tbls dbi)
    where
    createAttFD tbl = zip (filter hasName $ map cname (cols tbl)) 
		          (map descr (cols tbl))
    hasName a = a /= ""