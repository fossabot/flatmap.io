{-
    flatmap.io IT job search based on geo and technology.
    Copyright (C) 2019 Vadim Bakaev

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as
    published by the Free Software Foundation, either version 3 of the
    License, or (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Application
  ( getApplicationDev
  , appMain
  , develMain
  , makeFoundation
  , makeLogWare
    -- * for DevelMain
  , getApplicationRepl
  , shutdownApp
    -- * for GHCI
  , handler
  , db
  ) where

import Control.Applicative ()
import Control.Monad.Logger (liftLoc)
import Database.Persist.MongoDB (MongoContext)
import Import
import Language.Haskell.TH.Syntax (qLocation)
import Network.HTTP.Client.TLS (getGlobalManager)
import Network.Wai (Middleware)
import Network.Wai.Handler.Warp
  ( Settings
  , defaultSettings
  , defaultShouldDisplayException
  , getPort
  , runSettings
  , setHost
  , setOnException
  , setPort
  )
import Network.Wai.Middleware.RequestLogger
  ( Destination(Logger)
  , IPAddrSource(..)
  , OutputFormat(..)
  , destination
  , mkRequestLogger
  , outputFormat
  )
import System.Environment
import System.Log.FastLogger (defaultBufSize, newStdoutLoggerSet, toLogStr)

import Handler.Bookmarks
import Handler.Common
import Handler.Company
import Handler.Contacts
import Handler.Home
import Handler.Pending

-- This line actually creates our YesodDispatch instance. It is the second half
-- of the call to mkYesodData which occurs in Foundation.hs. Please see the
-- comments there for more details.
mkYesodDispatch "App" resourcesApp

-- | This function allocates resources (such as a database connection pool),
-- performs initialization and returns a foundation datatype value. This is also
-- the place to put your migrate statements to have automatic database
-- migrations handled by Yesod.
makeFoundation :: AppSettings -> IO App
makeFoundation appSettings
    -- Some basic initializations: HTTP connection manager, logger, and static
    -- subsite.
 = do
  appHttpManager <- getGlobalManager
  appLogger <- newStdoutLoggerSet defaultBufSize >>= makeYesodLogger
  appStatic <-
    (if appMutableStatic appSettings
       then staticDevel
       else static)
      (appStaticDir appSettings)
  appMapboxAccessToken <- pack <$> getEnv "MAPBOX_ACCESS_TOKEN"
  appMapQuestKey <- pack <$> getEnv "MAPQUEST_KEY"
  appOAuth2ClientId <- pack <$> getEnv "GITHUB_CLIENT_ID"
  appOAuth2ClientSecret <- pack <$> getEnv "GITHUB_SECRET"
    -- Create the database connection pool
  appConnPool <- createPoolConfig $ appDatabaseConf appSettings
  return $ App {..}

-- | Convert our foundation to a WAI Application by calling @toWaiAppPlain@ and
-- applying some additional middlewares.
makeApplication :: App -> IO Application
makeApplication foundation = do
  logWare <- makeLogWare foundation
    -- Create the WAI application and apply middlewares
  appPlain <- toWaiAppPlain foundation
  return $ logWare $ defaultMiddlewaresNoLogging appPlain

makeLogWare :: App -> IO Middleware
makeLogWare foundation =
  mkRequestLogger
    def
      { outputFormat =
          if appDetailedRequestLogging $ appSettings foundation
            then Detailed True
            else Apache
                   (if appIpFromHeader $ appSettings foundation
                      then FromFallback
                      else FromSocket)
      , destination = Logger $ loggerSet $ appLogger foundation
      }

-- | Warp settings for the given foundation value.
warpSettings :: App -> Settings
warpSettings foundation =
  setPort (appPort $ appSettings foundation) $
  setHost (appHost $ appSettings foundation) $
  setOnException
    (\_req e ->
       when (defaultShouldDisplayException e) $
       messageLoggerSource
         foundation
         (appLogger foundation)
         $(qLocation >>= liftLoc)
         "yesod"
         LevelError
         (toLogStr $ "Exception from Warp: " ++ show e))
    defaultSettings

-- | For yesod devel, return the Warp settings and WAI Application.
getApplicationDev :: IO (Settings, Application)
getApplicationDev = do
  settings <- getAppSettings
  foundation <- makeFoundation settings
  wsettings <- getDevSettings $ warpSettings foundation
  app <- makeApplication foundation
  return (wsettings, app)

getAppSettings :: IO AppSettings
getAppSettings = loadYamlSettings [configSettingsYml] [] useEnv

-- | main function for use by yesod devel
develMain :: IO ()
develMain = develMainHelper getApplicationDev

-- | The @main@ function for an executable running this site.
appMain :: IO ()
appMain
    -- Get the settings from all relevant sources
 = do
  settings <-
    loadYamlSettingsArgs
        -- fall back to compile-time values, set to [] to require values at runtime
      [configSettingsYmlValue]
        -- allow environment variables to override
      useEnv
    -- Generate the foundation from the settings
  foundation <- makeFoundation settings
    -- Generate a WAI Application from the foundation
  app <- makeApplication foundation
    -- Run the application with Warp
  runSettings (warpSettings foundation) app

--------------------------------------------------------------
-- Functions for DevelMain.hs (a way to run the app from GHCi)
--------------------------------------------------------------
getApplicationRepl :: IO (Int, App, Application)
getApplicationRepl = do
  settings <- getAppSettings
  foundation <- makeFoundation settings
  wsettings <- getDevSettings $ warpSettings foundation
  app1 <- makeApplication foundation
  return (getPort wsettings, foundation, app1)

shutdownApp :: App -> IO ()
shutdownApp _ = return ()

---------------------------------------------
-- Functions for use in development with GHCi
---------------------------------------------
-- | Run a handler
handler :: Handler a -> IO a
handler h = getAppSettings >>= makeFoundation >>= flip unsafeHandler h

-- | Run DB queries
db :: ReaderT MongoContext Handler a -> IO a
db = handler . runDB
