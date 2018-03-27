{-# LANGUAGE CPP                    #-}
{-# LANGUAGE DataKinds              #-}
{-# LANGUAGE DeriveDataTypeable     #-}
{-# LANGUAGE DeriveFunctor          #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs                  #-}
{-# LANGUAGE KindSignatures         #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE PolyKinds              #-}
{-# LANGUAGE ScopedTypeVariables    #-}
{-# LANGUAGE TypeFamilies           #-}
{-# LANGUAGE TypeOperators          #-}
{-# LANGUAGE UndecidableInstances   #-}
{-# OPTIONS_HADDOCK not-home        #-}

#include "overlapping-compat.h"
-- | This module provides facilities for adding headers to a response.
--
-- >>> let headerVal = addHeader "some-url" 5 :: Headers '[Header "Location" String] Int
--
-- The value is added to the header specified by the type (@Location@ in the
-- example above).
module Servant.API.ResponseHeaders
    ( -- * "Static" response headers, tracked at the type-level
      Headers(..)
    , ResponseHeader (..)
    , AddHeader
    , addHeader
    , noHeader
    , BuildHeadersTo(buildHeadersTo)
    , GetHeaders(getHeaders)
    , HeaderValMap
    , HList(..)

    , -- * "Dynamic" response headers
      DynHeaders(..)
    , withDynHeaders
    ) where

import           Data.ByteString.Char8     as BS
                 (ByteString, init, pack, unlines)
import qualified Data.CaseInsensitive      as CI
import           Data.Map
                 (Map)
import           Data.Proxy
import           Data.Typeable
                 (Typeable)
import           GHC.TypeLits
                 (KnownSymbol, Symbol, symbolVal)
import qualified Network.HTTP.Types.Header as HTTP
import           Web.HttpApiData
                 (FromHttpApiData, ToHttpApiData, parseHeader, toHeader)

import           Prelude ()
import           Prelude.Compat
import           Servant.API.Header
                 (Header)

-- | Response Header objects where each header name is tracked at the type-level.
--   You should never need to construct one directly. Instead, use
--   'addOptionalHeader'.
data Headers ls a = Headers { getResponse :: a
                            -- ^ The underlying value of a 'Headers'
                            , getHeadersHList :: HList ls
                            -- ^ HList of headers.
                            } deriving (Functor)

data ResponseHeader (sym :: Symbol) a
    = Header a
    | MissingHeader
    | UndecodableHeader ByteString
  deriving (Typeable, Eq, Show, Functor)

data HList a where
    HNil  :: HList '[]
    HCons :: ResponseHeader h x -> HList xs -> HList (Header h x ': xs)

type family HeaderValMap (f :: * -> *) (xs :: [*]) where
    HeaderValMap f '[]                = '[]
    HeaderValMap f (Header h x ': xs) = Header h (f x) ': HeaderValMap f xs


class BuildHeadersTo hs where
    buildHeadersTo :: [HTTP.Header] -> HList hs
    -- ^ Note: if there are multiple occurences of a header in the argument,
    -- the values are interspersed with commas before deserialization (see
    -- <http://www.w3.org/Protocols/rfc2616/rfc2616-sec4.html#sec4.2 RFC2616 Sec 4.2>)

instance OVERLAPPING_ BuildHeadersTo '[] where
    buildHeadersTo _ = HNil

instance OVERLAPPABLE_ ( FromHttpApiData v, BuildHeadersTo xs, KnownSymbol h )
         => BuildHeadersTo (Header h v ': xs) where
    buildHeadersTo headers =
      let wantedHeader = CI.mk . pack $ symbolVal (Proxy :: Proxy h)
          matching = snd <$> filter (\(h, _) -> h == wantedHeader) headers
      in case matching of
        [] -> MissingHeader `HCons` buildHeadersTo headers
        xs -> case parseHeader (BS.init $ BS.unlines xs) of
          Left _err -> UndecodableHeader (BS.init $ BS.unlines xs)
             `HCons` buildHeadersTo headers
          Right h   -> Header h `HCons` buildHeadersTo headers

-- * Getting

class GetHeaders ls where
    getHeaders :: ls -> [HTTP.Header]

instance OVERLAPPING_ GetHeaders (HList '[]) where
    getHeaders _ = []

instance OVERLAPPABLE_ ( KnownSymbol h, ToHttpApiData x, GetHeaders (HList xs) )
         => GetHeaders (HList (Header h x ': xs)) where
    getHeaders hdrs = case hdrs of
        Header val `HCons` rest -> (headerName , toHeader val):getHeaders rest
        UndecodableHeader h `HCons` rest -> (headerName,  h)  :getHeaders rest
        MissingHeader `HCons` rest -> getHeaders rest
      where headerName = CI.mk . pack $ symbolVal (Proxy :: Proxy h)

instance OVERLAPPING_ GetHeaders (Headers '[] a) where
    getHeaders _ = []

instance OVERLAPPABLE_ ( KnownSymbol h, GetHeaders (HList rest), ToHttpApiData v )
         => GetHeaders (Headers (Header h v ': rest) a) where
    getHeaders hs = getHeaders $ getHeadersHList hs

-- * Adding

-- We need all these fundeps to save type inference
class AddHeader h v orig new
    | h v orig -> new, new -> h, new -> v, new -> orig where
  addOptionalHeader :: ResponseHeader h v -> orig -> new  -- ^ N.B.: The same header can't be added multiple times


instance OVERLAPPING_ ( KnownSymbol h, ToHttpApiData v )
         => AddHeader h v (Headers (fst ': rest)  a) (Headers (Header h v  ': fst ': rest) a) where
    addOptionalHeader hdr (Headers resp heads) = Headers resp (HCons hdr heads)

instance OVERLAPPABLE_ ( KnownSymbol h, ToHttpApiData v
                       , new ~ (Headers '[Header h v] a) )
         => AddHeader h v a new where
    addOptionalHeader hdr resp = Headers resp (HCons hdr HNil)

-- | @addHeader@ adds a header to a response. Note that it changes the type of
-- the value in the following ways:
--
--   1. A simple value is wrapped in "Headers '[hdr]":
--
-- >>> let example1 = addHeader 5 "hi" :: Headers '[Header "someheader" Int] String;
-- >>> getHeaders example1
-- [("someheader","5")]
--
--   2. A value that already has a header has its new header *prepended* to the
--   existing list:
--
-- >>> let example1 = addHeader 5 "hi" :: Headers '[Header "someheader" Int] String;
-- >>> let example2 = addHeader True example1 :: Headers '[Header "1st" Bool, Header "someheader" Int] String
-- >>> getHeaders example2
-- [("1st","true"),("someheader","5")]
--
-- Note that while in your handlers type annotations are not required, since
-- the type can be inferred from the API type, in other cases you may find
-- yourself needing to add annotations.
addHeader :: AddHeader h v orig new => v -> orig -> new
addHeader = addOptionalHeader . Header

-- | Deliberately do not add a header to a value.
--
-- >>> let example1 = noHeader "hi" :: Headers '[Header "someheader" Int] String
-- >>> getHeaders example1
-- []
noHeader :: AddHeader h v orig new => orig -> new
noHeader = addOptionalHeader MissingHeader

-- | Combinator to use when you want your endpoint to return a response
--   along with some response headers, dynamically,
--   by simply building a value of type 'DynHeaders a', which is just a
--   response of type @a@ along with a map from header names to header values.
--
--   For all other interpretations than the server one, this combinator basically
--   has no effect and behaves just as if you were using @a@ directly.
data DynHeaders a = DynHeaders
  { dynResponse :: a
  , dynHeaders  :: Map HTTP.HeaderName ByteString
  } deriving (Typeable, Eq, Show, Functor)

-- | Build a \"response with headers\", where the headers are
--   provided at runtime as a 'Map' from header name to header value.
withDynHeaders :: a -> Map HTTP.HeaderName ByteString -> DynHeaders a
withDynHeaders = DynHeaders

-- $setup
-- >>> import Servant.API
-- >>> import Data.Aeson
-- >>> import Data.Text
-- >>> data Book
-- >>> instance ToJSON Book where { toJSON = undefined }
