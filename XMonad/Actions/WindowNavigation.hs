-----------------------------------------------------------------------------
-- |
-- Module      :  XMonad.Layout.WindowNavigation
-- Copyright   :  (c) 2007  David Roundy <droundy@darcs.net>,
--                          Devin Mullins <me@twifkak.com>
-- Maintainer  :  Devin Mullins <me@twifkak.com>
-- License     :  BSD3-style (see LICENSE)
--
-- This is a rewrite of "XMonad.Layout.WindowNavigation", for the purposes of
-- code cleanup and Xinerama support. It's not complete, so you'll want to
-- use that one for now.
--
-- WindowNavigation lets you assign keys to move up/down/left/right, based on
-- actual cartesian window coordinates, rather than just going j/k on the stack.
--
-----------------------------------------------------------------------------

module XMonad.Actions.WindowNavigation (
                                       -- * Usage
                                       -- $usage
                                       withWindowNavigation,
                                       withWindowNavigationKeys,
                                       WNAction(..),
                                       go, swap,
                                       Direction(..)
                                       ) where

import XMonad
import XMonad.Hooks.ManageDocks (Direction(..))
import qualified XMonad.StackSet as W

import Control.Applicative ((<$>))
import Control.Arrow (second)
import Data.IORef
import Data.List (sortBy)
import Data.Map (Map())
import qualified Data.Map as M
import Data.Maybe (catMaybes, fromMaybe, listToMaybe)
import Data.Ord (comparing)
import qualified Data.Set as S
import Graphics.X11.Xlib

-- $usage
--
-- Don't use it! What, are you crazy?

-- TODO:
--  - screen 1: 2x2, screen 2: 1 fs, move from scr 2 to scr 1: center -> border
--  - fix setPosition to use WNState
--  - cleanup
--  - documentation :)
--  - tests? (esp. for edge cases in currentPosition)
--  - solve the 2+3, middle right to bottom left problem
--  - manageHook to draw window decos?

withWindowNavigation :: (KeySym, KeySym, KeySym, KeySym) -> XConfig l -> IO (XConfig l)
withWindowNavigation (u,l,d,r) conf =
    withWindowNavigationKeys [ ((modMask conf              , u), WNGo   U),
                               ((modMask conf              , l), WNGo   L),
                               ((modMask conf              , d), WNGo   D),
                               ((modMask conf              , r), WNGo   R),
                               ((modMask conf .|. shiftMask, u), WNSwap U),
                               ((modMask conf .|. shiftMask, l), WNSwap L),
                               ((modMask conf .|. shiftMask, d), WNSwap D),
                               ((modMask conf .|. shiftMask, r), WNSwap R) ]
                             conf

withWindowNavigationKeys :: [((KeyMask, KeySym), WNAction)] -> XConfig l -> IO (XConfig l)
withWindowNavigationKeys wnKeys conf = do
    posRef <- newIORef M.empty
    return conf { keys = \cnf -> M.fromList (map (second (fromWNAction posRef)) wnKeys)
                                 `M.union` keys conf cnf }
  where fromWNAction posRef (WNGo dir)   = go   posRef dir
        fromWNAction posRef (WNSwap dir) = swap posRef dir

data WNAction = WNGo Direction | WNSwap Direction

type WNState = Map WorkspaceId Point

-- go:
-- 1. get current position, verifying it matches the current window
-- 2. get target windowrect
-- 3. focus window
-- 4. set new position
go :: IORef WNState -> Direction -> X ()
go = withTargetWindow W.focusWindow

swap :: IORef WNState -> Direction -> X ()
swap = withTargetWindow swapWithFocused
  where swapWithFocused targetWin winSet =
            case W.peek winSet of
                Just currentWin -> W.focusWindow currentWin $
                                   mapWindows (swapWin currentWin targetWin) winSet
                Nothing -> winSet
        mapWindows f ss = W.mapWorkspace (mapWindows' f) ss
        mapWindows' f ws@(W.Workspace { W.stack = s }) = ws { W.stack = mapWindows'' f <$> s }
        mapWindows'' f (W.Stack focused up down) = W.Stack (f focused) (map f up) (map f down)
        swapWin win1 win2 win = if win == win1 then win2 else if win == win2 then win1 else win

withTargetWindow :: (Window -> WindowSet -> WindowSet) -> IORef WNState -> Direction -> X ()
withTargetWindow adj posRef dir = fromCurrentPoint $ \win pos -> do
    targets <- filter ((/= win) . fst) <$> navigableTargets pos dir
    whenJust (listToMaybe targets) $ \(targetWin, targetRect) -> do
      windows (adj targetWin)
      setPosition posRef pos targetRect
  where fromCurrentPoint f = withFocused $ \win -> do
                                 currentPosition posRef >>= f win

-- Gets the current position from the IORef passed in, or if nothing (say, from
-- a restart), derives the current position from the current window. Also,
-- verifies that the position is congruent with the current window (say, if you
-- used mod-j/k or mouse or something).
-- TODO: worry about off-by-one issues with inside definition
currentPosition :: IORef WNState -> X Point
currentPosition posRef = do
    root <- asks theRoot
    currentWindow <- gets (W.peek . windowset)
    currentRect <- maybe (Rectangle 0 0 0 0) snd <$> windowRect (fromMaybe root currentWindow)

    wsid <- gets (W.tag . W.workspace . W.current . windowset)
    mp <- M.lookup wsid <$> io (readIORef posRef)

    case mp of
        Just p | p `inside` currentRect -> return p
        _                               -> return (middleOf currentRect)

  where Point px py `inside` Rectangle rx ry rw rh =
            px >= rx && px < rx + fromIntegral rw &&
            py >= ry && py < ry + fromIntegral rh

        middleOf (Rectangle x y w h) =
            Point (x + fromIntegral w `div` 2) (y + fromIntegral h `div` 2)
    -- return $ fromMaybe (Point 0 0) mp

-- TODO: use a smarter algorithm (with memory of last position)
setPosition :: IORef WNState -> Point -> Rectangle -> X ()
setPosition posRef _ (Rectangle x y w h) = do
    wsid <- gets (W.tag . W.workspace . W.current . windowset)
    let position = Point (x + (fromIntegral w `div` 2)) (y + (fromIntegral h `div` 2))
    io $ modifyIORef posRef $ M.insert wsid position

navigableTargets :: Point -> Direction -> X [(Window, Rectangle)]
navigableTargets point dir = navigable dir point <$> windowRects

-- Filters and sorts the windows in terms of what is closest from the Point in
-- the Direction.
navigable :: Direction -> Point -> [(Window, Rectangle)] -> [(Window, Rectangle)]
navigable d pt = sortby d . filter (inr d pt . snd)

-- Produces a list of normal-state windows, on any screen. Rectangles are
-- adjusted based on screen position relative to the current screen, because I'm
-- bad like that.
windowRects :: X [(Window, Rectangle)]
windowRects = fmap catMaybes . mapM windowRect . S.toList =<< gets mapped

windowRect :: Window -> X (Maybe (Window, Rectangle))
windowRect win = withDisplay $ \dpy -> do
    (_, x, y, w, h, _, _) <- io $ getGeometry dpy win
    return $ Just $ (win, Rectangle x y w h)
    `catchX` return Nothing

-- Modified from droundy's implementation of WindowNavigation.

-- TODO: simplify this
inr :: Direction -> Point -> Rectangle -> Bool
inr D (Point px py) (Rectangle rx ry w h) = px >= rx && px < rx + fromIntegral w &&
                                                        py < ry + fromIntegral h
inr U (Point px py) (Rectangle rx ry w _) = px >= rx && px < rx + fromIntegral w &&
                                            py >  ry
inr R (Point px py) (Rectangle rx ry _ h) = px <  rx &&
                                            py >= ry && py < ry + fromIntegral h
inr L (Point px py) (Rectangle rx ry w h) =             px > rx + fromIntegral w &&
                                            py >= ry && py < ry + fromIntegral h

sortby :: Direction -> [(a,Rectangle)] -> [(a,Rectangle)]
sortby D = sortBy $ comparing (rect_y . snd)
sortby R = sortBy $ comparing (rect_x . snd)
sortby U = reverse . sortby D
sortby L = reverse . sortby R