{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RecordWildCards #-}

module Handler.Pending where

import Data.Aeson
import Data.Geospatial.Internal.BasicTypes
import Data.Geospatial.Internal.GeoFeature
import Data.Geospatial.Internal.GeoFeatureCollection
import Data.Geospatial.Internal.Geometry

import Import

getPendingR :: Handler Html
getPendingR = do
  muser <- maybeAuth
  case muser of
    Nothing -> redirect HomeR
    Just (Entity _ user) ->
      if userIsAdmin user
        then do
          newCompanies <- runDB $ selectList [] []
          defaultLayout $ do
            let companies = toGeo newCompanies
            addScriptRemote "https://code.jquery.com/jquery-3.4.1.min.js"
            App {..} <- getYesod
            aDomId <- newIdent
            setTitle "Pending companies"
            $(widgetFile "pending")
        else redirect HomeR

toGeo :: [Entity NewCompany] -> GeoFeatureCollection (Entity NewCompany)
toGeo companies =
  GeoFeatureCollection Nothing (fromList $ map toGeoFeature companies)

toGeoFeature :: Entity NewCompany -> GeoFeature (Entity NewCompany)
toGeoFeature company =
  GeoFeature
    { _bbox = Nothing
    , _geometry =
        Point $
        GeoPoint $
        GeoPointXY $
        PointXY
          (coordinateLon $
           officeCoordinate $ newCompanyOffice $ entityVal company)
          (coordinateLat $
           officeCoordinate $ newCompanyOffice $ entityVal company)
    , _properties = company
    , _featureId = Nothing
    }