{-# LANGUAGE OverloadedStrings, RankNTypes #-}
-- | It should be noted that most of the code snippets below depend on the
-- OverloadedStrings language pragma.
--
-- The functions in this module allow an arbitrary monad to be embedded
-- in Scotty's monad transformer stack in order that Scotty be combined
-- with other DSLs.
module Web.Scotty.Trans
    ( -- * scotty-to-WAI
      scottyT, scottyAppT, scottyOptsT, Options(..)
      -- * Defining Middleware and Routes
      --
      -- | 'Middleware' and routes are run in the order in which they
      -- are defined. All middleware is run first, followed by the first
      -- route that matches. If no route matches, a 404 response is given.
    , middleware, get, post, put, delete, patch, addroute, matchAny, notFound
      -- ** Route Patterns
    , capture, regex, function, literal
      -- ** Accessing the Request, Captures, and Query Parameters
    , request, reqHeader, body, param, params, jsonData, files
      -- ** Modifying the Response and Redirecting
    , status, addHeader, setHeader, redirect
      -- ** Setting Cookies
    , setCookie, setCookie', getCookie
      -- ** Setting Response Body
      --
      -- | Note: only one of these should be present in any given route
      -- definition, as they completely replace the current 'Response' body.
    , text, html, file, json, source, raw
      -- ** Exceptions
    , raise, rescue, next, defaultHandler, ScottyError(..)
      -- * Parsing Parameters
    , Param, Parsable(..), readEither
      -- * Types
    , RoutePattern, File
      -- * Monad Transformers
    , ScottyT, ActionT
    ) where

import Blaze.ByteString.Builder (fromByteString)

import Control.Monad (when)
import Control.Monad.State (execStateT, modify)
import Control.Monad.IO.Class

import Data.Default (def)

import Network.HTTP.Types (status404)
import Network.Wai
import Network.Wai.Handler.Warp (Port, runSettings, settingsPort)

import Web.Scotty.Action
import Web.Scotty.Route
import Web.Scotty.Types hiding (Application, Middleware)
import qualified Web.Scotty.Types as Scotty

-- | Run a scotty application using the warp server.
-- NB: 'scotty p' === 'scottyT p id id'
scottyT :: (Monad m, MonadIO n)
        => Port
        -> (forall a. m a -> n a)      -- ^ Run monad 'm' into monad 'n', called once at 'ScottyT' level.
        -> (m Response -> IO Response) -- ^ Run monad 'm' into 'IO', called at each action.
        -> ScottyT e m ()
        -> n ()
scottyT p = scottyOptsT $ def { settings = (settings def) { settingsPort = p } }

-- | Run a scotty application using the warp server, passing extra options.
-- NB: 'scottyOpts opts' === 'scottyOptsT opts id id'
scottyOptsT :: (Monad m, MonadIO n)
            => Options
            -> (forall a. m a -> n a)      -- ^ Run monad 'm' into monad 'n', called once at 'ScottyT' level.
            -> (m Response -> IO Response) -- ^ Run monad 'm' into 'IO', called at each action.
            -> ScottyT e m ()
            -> n ()
scottyOptsT opts runM runActionToIO s = do
    when (verbose opts > 0) $
        liftIO $ putStrLn $ "Setting phasers to stun... (port " ++ show (settingsPort (settings opts)) ++ ") (ctrl-c to quit)"
    liftIO . runSettings (settings opts) =<< scottyAppT runM runActionToIO s

-- | Turn a scotty application into a WAI 'Application', which can be
-- run with any WAI handler.
-- NB: 'scottyApp' === 'scottyAppT id id'
scottyAppT :: (Monad m, Monad n)
           => (forall a. m a -> n a)      -- ^ Run monad 'm' into monad 'n', called once at 'ScottyT' level.
           -> (m Response -> IO Response) -- ^ Run monad 'm' into 'IO', called at each action.
           -> ScottyT e m ()
           -> n Application
scottyAppT runM runActionToIO defs = do
    s <- runM $ execStateT (runS defs) def
    let rapp = runActionToIO . foldl (flip ($)) notFoundApp (routes s)
    return $ foldl (flip ($)) rapp (middlewares s)

notFoundApp :: Monad m => Scotty.Application m
notFoundApp _ = return $ responseBuilder status404 [("Content-Type","text/html")]
                       $ fromByteString "<h1>404: File Not Found!</h1>"

-- | Global handler for uncaught exceptions. 
--
-- Uncaught exceptions normally become 500 responses. 
-- You can use this to selectively override that behavior.
defaultHandler :: Monad m => (e -> ActionT e m ()) -> ScottyT e m ()
defaultHandler f = ScottyT $ modify $ addHandler $ Just f

-- | Use given middleware. Middleware is nested such that the first declared
-- is the outermost middleware (it has first dibs on the request and last action
-- on the response). Every middleware is run on each request.
middleware :: Monad m => Middleware -> ScottyT e m ()
middleware = ScottyT . modify . addMiddleware
