module PGSimple.Functions
       ( -- * One-query functions for 'HasPostgres' instances
         pgWithTransaction
       , pgWithSavepoint
       , pgQuery
       , pgExecute
         -- * Inserting entities
       , pgInsertEntity
       , pgInsertManyEntities
       , pgInsertManyEntitiesId
         -- * Selecting entities
       , pgSelectEntities
       , pgSelectEntitiesBy
       , pgSelectJustEntities
       , pgGetEntity
       , pgGetEntityBy
         -- * Deleting entities
       , pgDeleteEntity
         -- * Updating entities
       , pgUpdateEntity
         -- * Counting entities
       , pgSelectCount
       , Qp(..)
       , MarkedRow(..)
       , ToMarkedRow(..)
       , mkIdent
       , mkValue
       , pgRepsertRow
       ) where

import Prelude

import Control.Applicative
import Control.Monad
import Control.Monad.Base
import Control.Monad.Logger
import Control.Monad.Trans.Control
import Data.Int ( Int64 )
import Data.Maybe ( listToMaybe )
import Data.Monoid
import Data.Proxy ( Proxy(..) )
import Data.Text ( Text )
import Data.Typeable ( Typeable )
import Database.PostgreSQL.Simple
    ( ToRow, FromRow, execute_, query_,
      withTransaction, withSavepoint )
import Database.PostgreSQL.Simple.FromField
    ( FromField )
import Database.PostgreSQL.Simple.ToField
    ( ToField )
import Database.PostgreSQL.Simple.Types
    ( Query(..), Only(..), (:.)(..) )
import PGSimple.Entity
    ( Entity(..), Ent )
import PGSimple.Internal
import PGSimple.SqlBuilder
import PGSimple.TH
import PGSimple.Types

import qualified Data.List as L
import qualified Data.Text.Encoding as T

-- | Execute all queries inside one transaction. Rollback transaction of exceptions
pgWithTransaction :: (HasPostgres m, MonadBaseControl IO m, TransactionSafe m)
                  => m a
                  -> m a
pgWithTransaction action = withPGConnection $ \con -> do
    control $ \runInIO -> do
        withTransaction con $ runInIO action

-- | Same as `pgWithTransaction` but executes queries inside savepoint
pgWithSavepoint :: (HasPostgres m, MonadBaseControl IO m, TransactionSafe m) => m a -> m a
pgWithSavepoint action = withPGConnection $ \con -> do
    control $ \runInIO -> do
        withSavepoint con $ runInIO action

-- | Execute query generated by 'SqlBuilder'. Typical use case:
-- @
-- let userName = "Vovka Erohin" :: Text
-- pgQuery [sqlExp| SELECT id, name FROM users WHERE name = #{userName}|]
-- @
--
-- Or
--
-- @
-- let userName = "Vovka Erohin" :: Text
-- pgQuery $ Qp "SELECT id, name FROM users WHERE name = ?" [userName]
-- @
--
-- Which is almost the same. In both cases proper value escaping is
-- performed
pgQuery :: (HasPostgres m, MonadLogger m, ToSqlBuilder q, FromRow r)
        => q -> m [r]
pgQuery q = withPGConnection $ \c -> do
    b <- liftBase $ runSqlBuilder c $ toSqlBuilder q
    logDebugN $ T.decodeUtf8 $ fromQuery b
    liftBase $ query_ c b

pgExecute :: (HasPostgres m, MonadLogger m, ToSqlBuilder q)
          => q -> m Int64
pgExecute q = withPGConnection $ \c -> do
    b <- liftBase $ runSqlBuilder c $ toSqlBuilder q
    logDebugN $ T.decodeUtf8 $ fromQuery b
    liftBase $ execute_ c b

pgInsertEntity :: forall a m. (HasPostgres m, MonadLogger m, Entity a,
                         ToRow a, FromField (EntityId a))
               => a
               -> m (EntityId a)
pgInsertEntity a = do
    pgQuery [sqlExp|^{insertEntity a} RETURNING id|] >>= \case
        ((Only ret):_) -> return ret
        _       -> fail "Query did not return any response"


-- | Select entities as pairs of (id, entity).
--
-- @
-- handler :: Handler [Ent a]
-- handler = do
--     pgSelectEntities False Nothing
--         "WHERE field = ? ORDER BY field2" [10]
--
-- handler2 :: Handler [Ent a]
-- handler2 = do
--     pgSelectEntities False (Just "t")
--         (mconcat
--          [ " AS t INNER JOIN table2 AS t2 "
--          , " ON t.t2_id = t2.id "
--           " WHERE t.field = ? ORDER BY t2.field2" ])
--         [10]
--    -- Here the query will be: SELECT ... FROM tbl AS t INNER JOIN ...
-- @
pgSelectEntities :: forall m a q. ( Functor m, HasPostgres m, MonadLogger m, Entity a
                            , FromRow a, ToSqlBuilder q, FromField (EntityId a) )
                 => (FN -> FN)
                 -> q            -- ^ part of query just after __SELECT .. FROM table__
                 -> m [Ent a]
pgSelectEntities fpref q = do
    map toTuples <$> pgQuery selectQ
  where
    toTuples ((Only eid) :. entity) = (eid, entity)
    p = Proxy :: Proxy a
    selectQ = [sqlExp|^{selectEntity (entityFieldsId fpref) p} ^{q}|]

-- | Same as 'pgSelectEntities' but do not select id
pgSelectJustEntities :: forall m a q. ( Functor m, HasPostgres m, MonadLogger m, Entity a
                                 , FromRow a, ToSqlBuilder q )
                     => (FN -> FN)
                     -> q
                     -> m [a]
pgSelectJustEntities fpref q = do
    let p = Proxy :: Proxy a
    pgQuery [sqlExp|^{selectEntity (entityFields id fpref) p} ^{q}|]

pgSelectEntitiesBy :: ( Functor m, HasPostgres m, MonadLogger m, Entity a, ToMarkedRow b
                     , FromRow a, FromField (EntityId a) )
                   => b -> m [Ent a]
pgSelectEntitiesBy b =
    let mr = toMarkedRow b
        q = if L.null $ unMR mr
            then mempty
            else [sqlExp|WHERE ^{mrToBuilder "AND" mr}|]
    in pgSelectEntities id q


-- | Select entity by id
--
-- @
-- getUser :: EntityId User ->  Handler User
-- getUser uid = do
--     pgGetEntity uid
--         >>= maybe notFound return
-- @
pgGetEntity :: forall m a. (ToField (EntityId a), Entity a,
                      HasPostgres m, MonadLogger m, FromRow a, Functor m)
            => EntityId a
            -> m (Maybe a)
pgGetEntity eid = do
    listToMaybe <$> pgSelectJustEntities id [sqlExp|WHERE id = #{eid} LIMIT 1|]


-- | Get entity by some fields constraint
--
-- @
-- getUser :: UserName -> Handler User
-- getUser name = do
--     pgGetEntityBy
--         [("name" :: Query, toField name),
--          ("active", toField True)]
--         >>= maybe notFound return
-- @
--
-- The query here will be like
--
-- @
-- pgQuery "SELECT id, name, phone ... FROM users WHERE name = ? AND active = ?" (name, True)
-- @
pgGetEntityBy :: forall m a b. ( Entity a, HasPostgres m, MonadLogger m, ToMarkedRow b
                         , FromField (EntityId a), FromRow a, Functor m )
              => b               -- ^ uniq constrained list of fields and values
              -> m (Maybe (Ent a))
pgGetEntityBy b =
    let mr = toMarkedRow b
        q = if L.null $ unMR mr
            then mempty
            else [sqlExp|WHERE ^{mrToBuilder "AND" mr} LIMIT 1|]
    in listToMaybe <$> pgSelectEntities id q


-- | Same as 'pgInsertEntity' but insert many entities at on
-- action. Returns list of id's of inserted entities
pgInsertManyEntitiesId :: forall a m. ( Entity a, HasPostgres m, MonadLogger m
                                , ToRow a, FromField (EntityId a))
                       => [a]
                       -> m [EntityId a]
pgInsertManyEntitiesId ents =
    let q = [sqlExp|^{insertManyEntities ents} RETURNING id|]
    in map fromOnly <$> pgQuery q

-- | Insert many entities without returning list of id like
-- 'pgInsertManyEntitiesId' does
pgInsertManyEntities :: forall a m. (Entity a, HasPostgres m, MonadLogger m, ToRow a)
                     => [a]
                     -> m ()
pgInsertManyEntities ents =
    void $ pgExecute $ insertManyEntities ents


-- | Delete entity.
--
-- @
-- rmUser :: EntityId User -> Handler ()
-- rmUser uid = do
--     pgDeleteEntity uid
-- @
pgDeleteEntity :: forall a m. (Entity a, HasPostgres m, MonadLogger m, ToField (EntityId a), Functor m)
               => EntityId a
               -> m ()
pgDeleteEntity eid =
    let p = Proxy :: Proxy a
    in (const ()) <$> pgExecute [sqlExp|DELETE FROM ^{mkIdent $ tableName p}
                                        WHERE id = #{eid}|]


-- | Update entity using 'ToMarkedRow' instanced value. Requires 'Proxy' while
-- 'EntityId' is not a data type.
--
-- @
-- fixVovka :: EntityId User -> Handler ()
-- fixVovka uid = do
--     pgGetEntity uid
--         >>= maybe notFound run
--   where
--     run user =
--         when ((userName user) == "Vovka")
--         $ pgUpdateEntity uid
--         (Proxy :: Proxy User)
--         [("active" :: Query, toField False)]
-- @
pgUpdateEntity :: forall a b m. (ToMarkedRow b, Entity a, HasPostgres m, MonadLogger m,
                           ToField (EntityId a), Functor m, Typeable a, Typeable b)
               => EntityId a
               -> b
               -> m ()
pgUpdateEntity eid b =
    let p = Proxy :: Proxy a
        mr = toMarkedRow b
    in if L.null $ unMR mr
       then return ()
       else fmap (const ())
            $ pgExecute [sqlExp|UPDATE ^{mkIdent $ tableName p}
                                SET ^{mrToBuilder ", " mr}
                                WHERE id = #{eid}|]

-- | Select count of entities with given query
--
-- @
-- activeUsers :: Handler Integer
-- activeUsers = do
--     pgSelectCount (Proxy :: Proxy User)
--         "WHERE active = ?" [True]
-- @
pgSelectCount :: forall m a q. ( Entity a, HasPostgres m, MonadLogger m, ToSqlBuilder q )
              => Proxy a
              -> q
              -> m Integer
pgSelectCount p q = do
    [[c]] <- pgQuery [sqlExp|SELECT count(id) FROM ^{mkIdent $ tableName p} ^{q}|]
    return c



-- | Perform repsert of the same row, first trying "update where" then "insert" with concatenated fields
pgRepsertRow :: (HasPostgres m, MonadLogger m, ToMarkedRow wrow, ToMarkedRow urow)
             => Text              -- ^ Table name
             -> wrow              -- ^ where condition
             -> urow              -- ^ update row
             -> m ()
pgRepsertRow tname wrow urow = do
    let wmr = toMarkedRow wrow
    aff <- pgExecute $ updateTable tname urow
           [sqlExp|WHERE ^{mrToBuilder "AND" wmr}|]
    when (aff == 0) $ do
        let umr = toMarkedRow urow
            imr = wmr <> umr
        _ <- pgExecute $ insertInto tname imr
        return ()
