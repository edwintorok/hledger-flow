{-# LANGUAGE OverloadedStrings #-}

module Common
    ( docURL
    , lsDirs
    , onlyDirs
    , onlyFiles
    , validDirs
    , filterPaths
    , basenameLine
    , buildFilename
    , shellToList
    , takeLast
    , firstLine
    , firstExistingFile
    , toIncludeLines
    , groupValuesBy
    , groupPairs
    , pairBy
    , includeFilePath
    , includePreamble
    , toIncludeFiles
    , toIncludeLine
    , generatedIncludeText
    , writeIncludeFiles'
    , writeIncludeFiles
    , writeJournals
    , writeJournals'
    , writeMakeItSoJournal
    ) where

import Turtle
import Prelude hiding (FilePath, putStrLn)
import qualified Data.Text as T
import Data.Maybe
import qualified Data.List.NonEmpty as NonEmpty
import qualified Control.Foldl as Fold
import qualified Data.Map.Strict as Map

import Data.Function (on)
import qualified Data.List as List (sort, sortBy, groupBy)
import Data.Ord (comparing)

groupPairs' :: (Eq a, Ord a) => [(a, b)] -> [(a, [b])]
groupPairs' = map (\ll -> (fst . head $ ll, map snd ll)) . List.groupBy ((==) `on` fst)
              . List.sortBy (comparing fst)

groupPairs :: (Eq a, Ord a) => [(a, b)] -> Map.Map a [b]
groupPairs = Map.fromList . groupPairs'

pairBy :: (a -> b) -> [a] -> [(b, a)]
pairBy keyFun = map (\v -> (keyFun v, v))

groupValuesBy :: (Ord k, Ord v) => (v -> k) -> [v] -> Map.Map k [v]
groupValuesBy keyFun = groupPairs . pairBy keyFun

docURL :: Line -> Text
docURL = format ("https://github.com/apauley/hledger-makeitso#"%l)

lsDirs :: FilePath -> Shell FilePath
lsDirs = validDirs . ls

onlyDirs :: Shell FilePath -> Shell FilePath
onlyDirs = filterPaths isDirectory

onlyFiles :: Shell FilePath -> Shell FilePath
onlyFiles = filterPaths isRegularFile

filterPaths :: (FileStatus -> Bool) -> Shell FilePath -> Shell FilePath
filterPaths filepred files = do
  path <- files
  filestat <- stat path
  if (filepred filestat) then select [path] else select []

validDirs :: Shell FilePath -> Shell FilePath
validDirs = excludeWeirdPaths . onlyDirs

excludeWeirdPaths :: Shell FilePath -> Shell FilePath
excludeWeirdPaths = findtree (suffix $ noneOf "_")

firstExistingFile :: [FilePath] -> Shell (Maybe FilePath)
firstExistingFile files = do
  case files of
    []   -> return Nothing
    file:fs -> do
      exists <- testfile file
      if exists then return (Just file) else firstExistingFile fs

basenameLine :: FilePath -> Shell Line
basenameLine path = case (textToLine $ format fp $ basename path) of
  Nothing -> die $ format ("Unable to determine basename from path: "%fp%"\n") path
  Just bn -> return bn

buildFilename :: [Line] -> Text -> FilePath
buildFilename identifiers ext = fromText (T.intercalate "-" (map lineToText identifiers)) <.> ext

shellToList :: Shell a -> Shell [a]
shellToList files = fold files Fold.list

takeLast :: Int -> [a] -> [a]
takeLast n = reverse . take n . reverse

firstLine :: Text -> Line
firstLine = NonEmpty.head . textToLines

toIncludeLines :: Shell FilePath -> Shell Line
toIncludeLines paths = do
  journalFile <- paths
  return $ fromMaybe "" $ textToLine $ format ("!include "%fp) journalFile

includeFileName :: FilePath -> FilePath
includeFileName = (<.> "journal"). fromText . (format (fp%"-include")) . dirname

includeFilePath :: FilePath -> FilePath
includeFilePath p = do
  (parent . parent) p </> includeFileName p

toIncludeFiles :: Map.Map FilePath [FilePath] -> Map.Map FilePath Text
toIncludeFiles fileMap = Map.mapWithKey generatedIncludeText fileMap

toIncludeLine :: FilePath -> FilePath -> Text
toIncludeLine base file = format ("!include "%fp) $ fromMaybe file $ stripPrefix (directory base) file

generatedIncludeText :: FilePath -> [FilePath] -> Text
generatedIncludeText outputFile files = do
  let lns = map (toIncludeLine outputFile) $ List.sort files
  T.intercalate "\n" $ includePreamble:(lns ++ [""])

includePreamble :: Text
includePreamble = "### Generated by hledger-makeitso - DO NOT EDIT ###\n"

writeIncludeFiles' :: [FilePath] -> Shell FilePath
writeIncludeFiles' = writeFiles . toIncludeFiles . groupValuesBy includeFilePath

writeIncludeFiles :: Shell FilePath -> Shell FilePath
writeIncludeFiles paths = shellToList paths >>= writeIncludeFiles'

writeFiles :: Map.Map FilePath Text -> Shell FilePath
writeFiles fileMap = do
  liftIO $ writeFiles' fileMap
  select $ Map.keys fileMap

writeFiles' :: Map.Map FilePath Text -> IO ()
writeFiles' fileMap = Map.foldlWithKey (\a k v -> a <> writeTextFile k v) (return ()) fileMap

writeJournals :: FilePath -> Shell FilePath -> Shell ()
writeJournals = writeJournals' sort

writeJournals' :: (Shell FilePath -> Shell [FilePath]) -> FilePath -> Shell FilePath -> Shell ()
writeJournals' sortFun aggregateJournal journals = do
  let journalBaseDir = directory aggregateJournal
  liftIO $ writeTextFile aggregateJournal $ includePreamble <> "\n"
  journalFiles <- sortFun journals
  journalFile <- uniq $ select journalFiles
  let strippedJournal = fromMaybe journalFile $ stripPrefix journalBaseDir journalFile
  liftIO $ append aggregateJournal $ toIncludeLines $ return $ strippedJournal

writeMakeItSoJournal :: FilePath -> Shell FilePath -> Shell ()
writeMakeItSoJournal baseDir importedJournals = do
  let importAggregateJournal = baseDir </> "import-all.journal"
  writeJournals importAggregateJournal importedJournals
  let manualDir = baseDir </> "manual"
  let pre = manualDir </> "pre-import.journal"
  let post = manualDir </> "post-import.journal"
  mktree manualDir
  touch pre
  touch post
  let makeitsoJournal = baseDir </> "makeitso.journal"
  writeJournals' shellToList makeitsoJournal $ select [pre, importAggregateJournal, post]
