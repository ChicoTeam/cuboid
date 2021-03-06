{-# LANGUAGE Arrows, BangPatterns, NamedFieldPuns #-}
module Update (update) where

import FRP.Yampa
import FRP.Yampa.Vector3
import FRP.Yampa.Utilities
import Graphics.UI.GLUT hiding (Level,Vector3(..),normalize)
import qualified Graphics.UI.GLUT as G(Vector3(..))

import Types 
import Utils
import Config
import Input

-- Logic
data WinLose = Win | Lose deriving (Eq)

-- Snapping integral 
integral' = (iPre zeroVector &&& time) >>> sscan f (zeroVector, 0) >>> arr fst
    where f (!prevVal, !prevTime) (!val, !time) 
            | val == zeroVector = 
                (vectorApply (fromIntegral . round) prevVal, time)
            | otherwise         = 
                (prevVal ^+^ (realToFrac $ time - prevTime) *^ val, time)

update :: SF ParsedInput GameState
update = proc pi@(ParsedInput{ wCount, aCount, sCount, dCount }) -> do
    rec speed    <- rSwitch selectSpeed -< ((pi, pos, speed, obstacles level),
                                            winLose `tag` selectSpeed)
        posi     <- drSwitch (integral') -< (speed, winLose `tag` integral')
        pos      <- arr calculatePPos -< (posi, level)
        winLose  <- arr testWinLoseCondition -< (pos, level)
        wins     <- arr (filterE (==Win)) >>> delayEvent 1 -< winLose 
        level    <- countHold >>^ fromInteger >>^ (levels !!) -< wins 
 
    -- TODO: watch for leak on wCount/aCount/sCount/dCount
    returnA -< Game { level     = level,
                      rotX      = realToFrac (wCount - sCount),
                      playerPos = pos }

    where calculatePPos (pos, level) = pos ^+^ (p3DtoV3 $ startingPoint level)
          testBounds pos size = let sizeN = fromInteger size
                                in vector3X pos > sizeN || vector3X pos < 0 ||
                                   vector3Y pos > sizeN || vector3Y pos < 0 ||
                                   vector3Z pos > sizeN || vector3Z pos < 0 
          -- TODO: Abstract further?
          testWinLoseCondition (pos, level)
            | norm (pos ^-^ (p3DtoV3 $ endPoint level)) < 0.5 = Event Win
            | testBounds pos (size level)                     = Event Lose
            | otherwise                                       = NoEvent
          countHold = count >>> hold 0

selectSpeed :: SF (ParsedInput, Vector3 R, Vector3 R, [Point3D]) 
                  (Vector3 R)
selectSpeed = proc (pi, pos, speed, obss) -> do
    let rotX = (fromInteger $ (floor $ (wCount pi) - (sCount pi)) 
                                `mod` 36 + 36) `mod` 36
        theta = (((rotX - 6) `div` 9) + 1) `mod` 4
    -- TODO: Get rid of the undefined? 
    speedC <- drSwitch (constant zeroVector) -< 
        (undefined, tagKeys (upEvs pi) speed ((-v) *^ zAxis) theta `merge` 
                    tagKeys (downEvs pi) speed (v *^ zAxis) theta `merge`
                    tagKeys (leftEvs pi) speed ((-v) *^ xAxis) theta `merge`
                    tagKeys (rightEvs pi) speed (v *^ xAxis) theta) 
    cols   <- collision ^>> boolToEvent -< (obss, pos, speedC)
    speedf <- rSwitch (constant zeroVector) -< (speedC, tagCols cols) 
    returnA -< speedf
    
    where xAxis = vector3 1 0 0 
          yAxis = vector3 0 1 0
          zAxis = vector3 0 0 1
          v     = 0.5
          -- TODO: make nicer? too many magical numbers & not 100% reliable
          collision (obss,pos,speed) = 
              any (\obs -> norm (pos ^+^ ((1/v) *^ speed) ^-^ (p3DtoV3 obs)) 
                            <= 0.4) obss
          -- TODO: Confusing names, can they be generalized?
          tagKeys event speed vector theta
              | speed == zeroVector = event `tag` constant 
                                        (vector3Rotate' theta vector)
              | otherwise           = NoEvent
          tagCols cols
              | isNoEvent cols  = Event identity
              | otherwise       = cols `tag` constant zeroVector
          boolToEvent = arr (\bool -> if bool then Event () else NoEvent)


