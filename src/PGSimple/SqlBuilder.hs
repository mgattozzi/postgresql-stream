module PGSimple.SqlBuilder where

import Prelude

import Blaze.ByteString.Builder ( Builder )
import Control.Applicative
import Control.Exception
import Data.ByteString ( ByteString )
import Data.Monoid
import Data.String
import Data.Typeable ( Typeable )
import Database.PostgreSQL.Simple
import Database.PostgreSQL.Simple.ToField
import GHC.Generics ( Generic )

import qualified Blaze.ByteString.Builder.ByteString as BB
import qualified Blaze.ByteString.Builder.Char.Utf8 as BB
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Lazy as TL

newtype SqlBuilder =
    SqlBuilder
    { sqlBuild :: Connection -> IO Builder }
    deriving (Typeable, Generic)

instance IsString SqlBuilder where
    fromString s =
        let b = fromString s :: ByteString
        in toSqlBuilder b

class ToSqlBuilder a where
    toSqlBuilder :: a -> SqlBuilder

instance ToSqlBuilder SqlBuilder where
    toSqlBuilder = id
instance ToSqlBuilder Builder where
    toSqlBuilder = sqlBuilderPure
instance ToSqlBuilder ByteString where
    toSqlBuilder = sqlBuilderPure . BB.fromByteString
instance ToSqlBuilder BL.ByteString where
    toSqlBuilder = sqlBuilderPure . BB.fromLazyByteString
instance ToSqlBuilder String where
    toSqlBuilder = sqlBuilderPure . BB.fromString
instance ToSqlBuilder T.Text where
    toSqlBuilder = sqlBuilderPure . BB.fromText
instance ToSqlBuilder TL.Text where
    toSqlBuilder = sqlBuilderPure . BB.fromLazyText
instance ToRow row => ToSqlBuilder (Query, row) where
    toSqlBuilder (q, row) = SqlBuilder $ \c ->
        BB.fromByteString <$> formatQuery c q row



sqlBuilderPure :: Builder -> SqlBuilder
sqlBuilderPure b = SqlBuilder $ const $ pure b

sqlBuilderFromField :: (ToField a) => Query -> a -> SqlBuilder
sqlBuilderFromField q a =
    SqlBuilder $ \c -> buildAction c q $ toField a

instance Monoid SqlBuilder where
    mempty = sqlBuilderPure mempty
    mappend (SqlBuilder a) (SqlBuilder b) =
        SqlBuilder $ \c -> mappend <$> (a c) <*> (b c)


throwFormatError :: Query -> ByteString -> a
throwFormatError q msg = throw
             $ FormatError
               { fmtMessage = utf8ToString msg
               , fmtQuery = q
               , fmtParams = [] --  FIXME: Maybe paste something here
               }
  where
    utf8ToString = T.unpack . T.decodeUtf8


quoteOrThrow :: Query -> Either ByteString ByteString -> Builder
quoteOrThrow q = either (throwFormatError q) (inQuotes . BB.fromByteString)

-- | Shity copy-paste from postgresql-simple
buildAction :: Connection -> Query -> Action -> IO Builder
buildAction _ _ (Plain b)            = pure b
buildAction c q (Escape s)           = quoteOrThrow q <$> escapeStringConn c s
buildAction c q (EscapeByteA s)      = quoteOrThrow q <$> escapeByteaConn c s
buildAction c q (EscapeIdentifier s) = either (throwFormatError q) BB.fromByteString
                                     <$> escapeIdentifier c s
buildAction c q (Many  ys)           = mconcat <$> mapM (buildAction c q) ys
