--------------------------------------------------------------------------------
{-# LANGUAGE OverloadedStrings #-}
import           Data.List (isSuffixOf, find)
import           Control.Monad (filterM, liftM)
import           System.Environment (lookupEnv)
import           Hakyll
import           Data.Monoid ((<>))

------------------------
-- Overview
------------------------
--
-- Generates static web page.
--
-- Identifier - In essence, a file path (e.g. posts/123.html, index). Can be
--              actual (the file posts/123.html exists) or virtual (you create
--              the file myblogpost.html from myblogpost.markdown).
--
-- Metadata   - Map String String. Get Metadata from an Identifier.
--
-- Item       - Some kind of content (of a file) and its Identifier. Has
--              Identifier so that you can get the metadata from the file.
--
--              For our custom Items (project items), we can ignore the
--              Identifier (use a fake one), since the Context we would use
--              doesn't need to actually load a file (none exists).
--
-- Context    - Hakyll templates uses variables like $title$ as placeholders.
--              A Context describes *how* to get the value of a field.
--
--              For example, a `Context a` is in essence, a mapping of String
--              keys to a function takes an `Item a` and returns a Compiler for
--              type `a`.
--
--              Mostly you see `Context String`. But we have, for the projects
--              listing, a `Context CustomProjectDataType`, which knows how to
--              look into a CustomProjectDataType to find the fields it needs to
--              inject into `Item CustomProjectDataType`s.
--
--              At the end of the day, a Context + Item is applied to a template
--              via methods like applyTemplate.
--
--              Check out how the `field` function, which constructs a new field
--              in the Context, takes a function of (Item a -> Compiler String):
--              http://jaspervdj.be/hakyll/reference/src/Hakyll-Web-Template-Context.html#field
--
-- Rules      - Monad DSL for declaring routes and compliers. What the `hakyll`
--              function works in.
--
-- Resources:
--
-- https://jaspervdj.be/hakyll/tutorials/a-guide-to-the-hakyll-module-zoo.html

--------------------------------------------------------------------------------
main :: IO ()
main = do
  loadDraftsEnv <- lookupEnv "LOAD_DRAFTS"
  let loadDrafts = maybe False (=="true") loadDraftsEnv
  hakyll $ do
    ------------------------
    -- Static
    ------------------------

    match "images/**" $ do
        route   idRoute
        compile copyFileCompiler

    match "css/fonts/**" $ do
        route   idRoute
        compile copyFileCompiler

    match "p/**" $ do
        route   idRoute
        compile copyFileCompiler

    match "css/*" $ do
        route   idRoute
        compile compressCssCompiler

    ------------------------
    -- Dynamic
    ------------------------

    -- Load all posts. If the environemnt specifies, filter out draft posts.
    -- Create [Identifier] and Pattern, since functions differ on which one they
    -- use.
    postIds <- findAllPostIds loadDrafts
    let postsPattern = fromList postIds

    -- `Tags` contains:
    -- * tagsMap    - A list of tag strings paired with Identifiers it was found on
    -- * tagsMakeId - A function to convert a tag (String) to an Identifier
    --   (some *new* path for the canonical URL of a tag, e.g. tags/haskell.html).
    --
    -- Search metadata in blob Pattern for tags.
    --
    -- `(fromCapture ...)` expression returns function that fills in the `*` in the
    -- capture, given a string.
    --
    tags <- buildTags postsPattern (fromCapture "blog/tags/*.html")

    -- Generate a page for each tag in the Rules monad.
    --
    -- `pattern` is list of posts with the given `tag`.
    tagsRules tags $ \tag pattern -> do
        let title = "Posts tagged with \"" ++ tag ++ "\""
        route idRoute
        compile $ do
            posts <- recentFirst =<< loadAll pattern
            let ctx = constField "title" title `mappend`
                      listField "posts" postContext (return posts) `mappend`
                      defaultContext

            makeItem ""
                >>= loadAndApplyTemplate "templates/tag.html" ctx
                >>= loadAndApplyTemplate "templates/default.html" ctx
                >>= relativizeUrls

    match postsPattern $ do
        route $ customRoute formatFilename
        compile $ pandocCompiler
            -- Render just the post body first, so that I can `saveSnapshot`
            -- just the body for the Atom feed.
            >>= loadAndApplyTemplate "templates/post-body.html"    (postContextWithTags tags)
            >>= saveSnapshot postContentSnapshot
            >>= loadAndApplyTemplate "templates/post.html"    (postContextWithTags tags)
            >>= loadAndApplyTemplate "templates/default.html" (postContextWithTags tags)
            >>= processUrls

    create ["projects/index.html"] $ do
        route idRoute
        compile $ do
            -- The `projCtx` context knows how to query into a Project
            let ctx = listField "projects" projCtx (return projectItems) <> constField "title" "Elben Shira - Projects"

            template <- loadBody "templates/projects.html"

            -- Need to start with an empty string Item, then apply the project
            -- list template with our built project context, then put all of
            -- that HTML into the default template.
            makeItem ("" :: String)
              >>= applyTemplate template ctx
              >>= loadAndApplyTemplate "templates/default.html" (ctx <> defaultContext)
              >>= processUrls

    create ["blog/index.html"] $ do
        route idRoute
        compile $ do
            posts <- recentFirst =<< loadAllIds postIds
            let archiveCtx =
                    listField "posts" postContext (return posts) `mappend`
                    constField "title" "Elben Shira - Blog Archives"            `mappend`
                    defaultContext

            makeItem ""
                >>= loadAndApplyTemplate "templates/archive.html" archiveCtx
                >>= loadAndApplyTemplate "templates/default.html" archiveCtx
                >>= processUrls

    create ["blog/atom.xml"] $ do
        route idRoute
        compile $ renderAtomFeedForPattern postsPattern

    -- For http://planet.clojure.in/, which subscribes to my feed
    create ["blog/tags/clojure.xml"] $ do
        route idRoute
        compile $ renderAtomFeedForPattern (filterByTag tags "clojure")

    -- Handle projects/index.html, which already exists
    create ["projects/index.html"] $ do
        -- Route final generated file to the same path as above
        route idRoute

        compile $ do
            let ctx = defaultContext

            getResourceBody
                >>= applyAsTemplate ctx
                >>= loadAndApplyTemplate "templates/default.html" ctx

    match "index.html" $ do
        route idRoute
        compile $ do
            posts <- recentFirst =<< loadAllIds postIds

            recPosts <- recentFirst =<< loadAll (filterByTag tags "recommended")

            -- Build context for the template (set template variable values)
            let indexCtx =
                    listField "posts" postContext (return posts)               `mappend`
                    listField "recommendedPosts" postContext (return recPosts) `mappend`
                    constField "title" websiteTitle                            `mappend`
                    defaultContext
            getResourceBody
                >>= applyAsTemplate indexCtx
                >>= loadAndApplyTemplate "templates/default.html" indexCtx
                >>= processUrls

    match "templates/*" $ compile templateCompiler

websiteTitle :: String
websiteTitle = "Elben Shira"

-- Name for snapshop that contains only the blog post body, without title or
-- other metadata.
postContentSnapshot :: String
postContentSnapshot = "content"

-- Render Atom feed for the pattern of posts.
renderAtomFeedForPattern :: Pattern -> Compiler (Item String)
renderAtomFeedForPattern pattern = do
    posts <- fmap (take 10) (recentFirst =<< loadAllSnapshots pattern postContentSnapshot)
    renderAtom atomFeedConfiguration feedContext posts

-- Use the body of the post in the 'description' field.
feedContext :: Context String
feedContext = postContext `mappend` bodyField "description"

postContext :: Context String
postContext =
    dateField "date" "%e %B %Y"            `mappend`
    defaultContext

-- `tagsField` renders tags with links. Puts it in the "tags" field context.
--
-- It gets the right tags with `tagsField`, which re-searches the Identifier to
-- get the tags for that page, then looks at the given `tags` to find the URL to
-- route it to (e.g. tags/haskell.html). See
-- http://jaspervdj.be/hakyll/reference/src/Hakyll-Web-Tags.html#tagsFieldWith
--
postContextWithTags :: Tags -> Context String
postContextWithTags tags = tagsField "tags" tags `mappend` postContext

-- Given the retrieved Tags and a tag, find all posts that contain the tag.
-- Returns a Pattern list of posts.
filterByTag :: Tags -> String -> Pattern
filterByTag tags tag = case find (\(tag', _) -> tag' == tag) (tagsMap tags) of
                         Just (_, identifiers) -> fromList identifiers
                         Nothing               -> fromList []

-- liftM promotes the `maybe ...` function into the MonadMetadata monad.
-- liftM :: Monad m => (a1 -> r) -> (m a1 -> m r)
isNotDraft :: MonadMetadata m => Identifier -> m Bool
isNotDraft i = liftM (maybe True (/= "true")) (getMetadataField i "draft")
-- Equivalent:
-- isNotDraft i = getMetadataField i "draft" >>= return . (maybe True (/="true"))

findAllPostIds :: MonadMetadata m
               => Bool
               -- ^ Include drafts if true.
               -> m [Identifier]
findAllPostIds includeDrafts = do
  ids <- getMatches "posts/*"
  if includeDrafts then return ids else filterM isNotDraft ids

loadAllIds :: [Identifier] -> Compiler [Item String]
loadAllIds = mapM load

-- TODO fix to do better
-- From "posts/yyyy-mm-dd-post-title.markdown" to "blog/post-title/index.html"
formatFilename :: Identifier -> String
formatFilename ident = "blog/" ++ takeWhile (/= '.') (drop 17 (toFilePath ident)) ++ "/index.html"

processUrls :: Item String -> Compiler (Item String)
processUrls i = relativizeUrls i >>= cleanIndexUrls

-- Original from https://groups.google.com/forum/#!topic/hakyll/s1SgkIzRdMQ
--
-- Strips "index.html" from non-external URLs in Item.
cleanIndexUrls :: Item String -> Compiler (Item String)
cleanIndexUrls = return . fmap (withUrls clean)
  where
    idx = "index.html"
    clean url
        | idx `isSuffixOf` url && (not . isExternal) url = take (length url - length idx) url
        | otherwise = url

atomFeedConfiguration :: FeedConfiguration
atomFeedConfiguration = FeedConfiguration
    { feedTitle       = websiteTitle
    , feedDescription = ""
    , feedAuthorName  = "Elben Shira"
    , feedAuthorEmail = "elbenshira@gmail.com"
    , feedRoot        = "http://elbenshira.com"
    }

data Project = Project {
  projName      :: String,
  projSourceUrl :: String,
  projPageUrl   :: Maybe String,
  projDesc      :: String
} deriving (Eq, Show)

-- Project description
--
-- Note, the projDesc field supports Markdown
projects :: [Project]
projects =
  [ Project "Neblen" "https://github.com/elben/neblen" Nothing
      "A programming language that focuses on type safety with Lisp simplicity. In essence, the typed lambda calculus, with some added features like polymorphic type variables and algebraic data types. Includes a parser, type checker, and interpreter. For educational purposes."

  , Project "SAT" "https://github.com/elben/sat" Nothing
      "Boolean satisfiability Haskell library to help you solve those NP-hard problems."

  , Project "True Cost" "https://github.com/true-cost/" Nothing
      "Calculates the true cost of your spending. Written in Elm."

  , Project "Planjure" "https://github.com/elben/planjure" (Just "/p/planjure")
      "Path-planning demo running Dijkstra and A*. A study in ClojureScript, Om and core.async."

  , Project "K-means" "https://github.com/elben/k-means" Nothing
      "A demo of the k-means clustering algorithm written in Clojure and Quill."

  , Project "Curvey" "https://github.com/elben/curvey" (Just "/p/curvey")
      "B-spline editor and demo that doesn't suck (as much)."

  , Project "Iron Tools" "https://github.com/jasontbradshaw/iron-tools" Nothing
      "Stream live HD video for conferences."

  , Project "Kapal" "https://github.com/elben/kapal" Nothing
      "Get a robot from Point A to Point B. Path-planning library in Python."

  , Project "See more on GitHub" "https://github.com/elben?tab=repositories" Nothing ""
  ]

projectItems :: [Item Project]
projectItems = map (\p -> Item { itemIdentifier = fromFilePath "fake", itemBody = p }) projects

projNameCtx :: Context Project
projNameCtx = field "name" $ \item -> return $ projName $ itemBody item

-- Primary URL for project.
--
-- Defaults to the source code URL. But if a page URL also exists, use the
-- page URL instead.
--
projMainUrlCtx :: Context Project
projMainUrlCtx = field "url" $ \item -> do
  let proj = itemBody item
  case projPageUrl proj of
    Just url -> return url
    Nothing  -> return $ projSourceUrl proj

-- Secondary source URL.
--
-- Return the source code URL for projects that have both a page URl and a
-- source code URL. For projects that only have a source code URL, return an
-- empty URl for this one, because this is considered the secondary URL.
--
projOptSrcUrlCtx :: Context Project
projOptSrcUrlCtx = field "source_url" $ \item -> do
  let proj = itemBody item
  case projPageUrl proj of
    Just _  -> return $ projSourceUrl proj
    Nothing ->
      -- Compiler is a Monad and it implements `fail`. A (bad) way of telling
      -- the compiler that this field is unwanted. This is so that the template
      -- does not see a $source_url$ field, and thus we can use $if(source_url_$
      -- in the template.
      --
      -- https://github.com/jaspervdj/hakyll/blob/b810fe38cf2eddb67b8fa9e56434ce5dbde4f22e/src/Hakyll/Core/Compiler/Internal.hs#L145
      fail "We don't want a secondary source URL"

-- Project description.
--
-- TODO: compile using markdown compiler. Probably will need to call Pandoc's
-- readMarkdown directly. The Hakyll pandocCompiler works with Compiler (Item
-- String) (because it needs to read the item's file extension to know which
-- parser to use), not Compiler String.
projDescriptionCtx :: Context Project
projDescriptionCtx = field "description" $ \item ->
    return $ projDesc $ itemBody item

-- A context that knows how to query into the project tuple. So if the context
-- is paired with an Item Project, it can grab the elements it needs out of the
-- Project.
projCtx :: Context Project
projCtx = projNameCtx <> projMainUrlCtx <> projDescriptionCtx <> projOptSrcUrlCtx

