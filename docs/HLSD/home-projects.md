# Home tab: project lists

The Home tab's main board (`resources/web/homepage`) has two project lists.

- **Recently opened** is this app's recent-projects history (`MainFrame::get_recent_projects`), shown
  as one row: the page hides the cards that would wrap (`ApplyRecentRowCap` in `js/home.js`).
- **All projects** lists every project file the app can find: the 3MF projects in the folders the
  person chose (app config section `project_folders`), plus the projects in the recent lists of this
  app and of the other slicers installed (OrcaSlicer, Bambu Studio, the Orca forks and PrusaSlicer,
  found by `OtherSlicers::find`). Each file is listed once, newest first, with the slicers that
  opened it.

Both lists share one item template and switch together between cards and rows (card or list view,
remembered per machine in the page's local storage).

## Finding the projects

`ProjectLibrary::collect` (`src/libslic3r/ProjectLibrary.{hpp,cpp}`) does the search and is unit
tested. A file found in a folder counts as a project only when it is a 3MF that a slicer saved with
its settings (`Metadata/project_settings.config` for the Orca family, `Metadata/Slic3r_PE.config` for
the PrusaSlicer family). Only the archive's central directory is read for that. Plain model 3MFs and
sliced `.gcode.3mf` files are left out. Files from a recent list are taken as projects without the
check, since a slicer opened them as one.

The search runs on a worker thread (`WebViewPanel::SendAllProjects`) when the page loads, when a
folder is added or removed, on **Refresh**, and when the recent list changes (at most every 15
seconds). It is bounded in depth, project count and entries visited, so choosing a whole drive
cannot stall it, and it stops when the app closes. A newer search supersedes one still running.

## Cloud-only files

Documents folders are often synced by OneDrive or a similar Files On-Demand service. Reading a
placeholder file downloads it, so a search would pull the whole library down. Such files
(`ProjectLibrary::is_cloud_only`, from the Windows file attributes) are listed without being opened:
no project check and no thumbnail.

## Thumbnails

The list is sent without pictures. The page asks for the thumbnails of the cards scrolling into view,
in batches (`homepage_get_project_thumbnails`), and `WebViewPanel::SendProjectThumbnails` reads them
from the 3MFs on a worker thread. Recent projects keep the thumbnails `MainFrame` already loads.
