;;; project-x.el --- File-defined projects for project.el -*- lexical-binding: t; -*-

;; Author: myjung
;; Keywords: project, tools
;; Package-Requires: ((emacs "30.1"))

;;; Commentary:

;; project-x provides .projx workspace files for Emacs project.el.
;; A .projx file is the project identity, and its containing directory is
;; the project root.  The project may include files/folders outside that root
;; and may import build-system metadata such as Visual Studio solutions.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'project)
(require 'seq)
(require 'subr-x)

(defvar lsp-clients-clangd-args)
(declare-function lsp-session-folders "lsp-mode")
(declare-function lsp-workspaces "lsp-mode")
(declare-function lsp--workspace-server-id "lsp-mode")
(declare-function lsp--workspace-proc "lsp-mode")
(declare-function lsp--workspace-buffers "lsp-mode")
(declare-function lsp--workspace-root "lsp-mode")
(declare-function lsp-workspace-restart "lsp-mode")

(defgroup project-x nil
  "File-defined projects for project.el."
  :group 'project)

(defcustom project-x-file-extension ".projx"
  "File extension used by project-x project files."
  :type 'string
  :group 'project-x)

(defcustom project-x-recent-projects-file
  (locate-user-emacs-file "project-x-recent-projects")
  "File used to persist recently activated project-x project files."
  :type 'file
  :group 'project-x)

(defcustom project-x-msbuild-extractor-executable
  (or (executable-find "msbuild-extractor-sample")
      (expand-file-name "~/tools/bin/msbuild-extractor-sample/msbuild-extractor-sample.exe"))
  "Executable used to extract compile_commands.json from Visual Studio solutions."
  :type 'string
  :group 'project-x)

(defcustom project-x-default-configuration "Debug"
  "Default Visual Studio configuration used by solution imports."
  :type 'string
  :group 'project-x)

(defcustom project-x-default-platform "x64"
  "Default Visual Studio platform used by solution imports."
  :type 'string
  :group 'project-x)

(defcustom project-x-vs-project-item-tags
  '("ClCompile" "ClInclude" "None" "Text" "ResourceCompile" "Image" "MASM")
  "Visual Studio project item tags imported as project-x files."
  :type '(repeat string)
  :group 'project-x)

(defcustom project-x-auto-lsp-modes
  '(c-mode c++-mode c-ts-mode c++-ts-mode)
  "Major modes where project-x may start LSP automatically.
This only applies when a project-x project is active and the opened file
belongs to that project-x project."
  :type '(repeat symbol)
  :group 'project-x)

(defcustom project-x-auto-lsp-strict-membership nil
  "When non-nil, only auto-start LSP for files listed in project-x.
When nil, auto-start LSP for C/C++ buffers while a project-x project is
active.  This keeps definition-jump-opened headers responsive, including
headers that are only reachable through compiler include paths."
  :type 'boolean
  :group 'project-x)

(defcustom project-x-refresh-restart-lsp t
  "Restart existing project clangd workspaces after a successful refresh.
Only workspaces attached to file buffers associated with the refreshed
project are considered.  Shared workspaces require confirmation and are
skipped in batch mode.  No language servers are started for unmanaged files."
  :type 'boolean
  :group 'project-x)

(defconst project-x--default-msbuild-extractor-path
  (expand-file-name "~/tools/bin/msbuild-extractor-sample/msbuild-extractor-sample.exe")
  "Fallback path for the MSBuild extractor installed on this machine.")

(defconst project-x--cache-miss (make-symbol "project-x-cache-miss")
  "Sentinel for cached nil values.")

(defvar project-x--active-project nil
  "Default project-x project object.")

(defvar-local project-x-buffer-project nil
  "Project-x project associated with the current buffer.")

(defvar project-x--context-project nil
  "Project-x project temporarily propagated while opening related files.")

(defvar project-x--project-cache (make-hash-table :test 'equal)
  "Cache of parsed project-x projects keyed by .projx file path.")

(defvar project-x--files-cache (make-hash-table :test 'equal)
  "Cache of project-x file lists keyed by .projx file path.")

(defvar project-x--include-dirs-cache (make-hash-table :test 'equal)
  "Cache of include directories keyed by .projx file path.")

(defvar project-x--compile-metadata-cache (make-hash-table :test 'equal)
  "Cache of imported source files and include dirs keyed by .projx file path.")

(defvar project-x--source-dirs-cache (make-hash-table :test 'equal)
  "Cache of source directories keyed by .projx file path.")

(defvar project-x--membership-cache (make-hash-table :test 'equal)
  "Cache of normalized membership data keyed by .projx file path.")

(defvar project-x--projects-for-file-cache (make-hash-table :test 'equal)
  "Cache of loaded project-x projects keyed by normalized file path.")

(defvar project-x--path-key-cache (make-hash-table :test 'equal)
  "Cache of normalized absolute path keys.")

(defvar project-x--recent-project-files nil
  "Recently activated project-x project file paths.")

(defvar project-x--recent-projects-loaded nil
  "Non-nil after `project-x--recent-project-files' has been loaded.")

(defvar project-x-mode-line-string ""
  "Compatibility variable for older project-x mode-line entries.")

(defvar-local project-x--cached-mode-line-string ""
  "Cached project-x mode-line text for the current buffer.")

(defvar-local project-x--mode-line-cache-state nil
  "State used to avoid unnecessary project-x mode-line cache refreshes.")

(defvar-keymap project-x-open-map
  :doc "Keymap for opening project-x projects."
  "o" #'project-x-open
  "p" #'project-x-open-recent)

(defvar-keymap project-x-close-map
  :doc "Keymap for closing project-x projects."
  "c" #'project-x-close)

(defvar-keymap project-x-map
  :doc "Keymap for project-x commands."
  "o" project-x-open-map
  "c" project-x-close-map
  "i" #'project-x-import-visual-studio-solution
  "r" #'project-x-refresh
  "f" #'project-x-find-file
  "s" #'project-x-switch-buffer-project)

(defun project-x--hash-get (hash key &optional default)
  "Return from HASH the value for KEY or DEFAULT."
  (if (hash-table-p hash)
      (gethash key hash default)
    default))

(defun project-x--string-list (value)
  "Return VALUE as a list of strings."
  (cond
   ((null value) nil)
   ((vectorp value) (seq-filter #'stringp (append value nil)))
   ((listp value) (seq-filter #'stringp value))
   ((stringp value) (list value))
   (t nil)))

(defun project-x--json-read-file (file)
  "Read JSON object from FILE as hash tables and vectors."
  (with-temp-buffer
    (insert-file-contents file)
    (json-parse-buffer :object-type 'hash-table :array-type 'array
                       :false-object nil :null-object nil)))

(defun project-x--project-file-p (file)
  "Return non-nil when FILE is a project-x project file."
  (and file (string-equal (file-name-extension file t)
                          project-x-file-extension)))

(defun project-x--directory-files-recursive (dir)
  "Return regular files under DIR recursively."
  (when (file-directory-p dir)
    (directory-files-recursively dir ".*" nil
                                 (lambda (subdir)
                                   (not (member (file-name-nondirectory
                                                 (directory-file-name subdir))
                                                '("." ".." ".git" ".hg" ".svn")))))))

(defun project-x--as-directory (path)
  "Return PATH as an expanded directory name."
  (file-name-as-directory (expand-file-name path)))

(defun project-x--path-key (path)
  "Return normalized PATH for comparisons."
  (let ((cacheable (and (stringp path)
                        (or (file-name-absolute-p path)
                            (string-prefix-p "~" path)))))
    (or (and cacheable (gethash path project-x--path-key-cache))
        (let ((expanded (expand-file-name path)))
          (when (eq system-type 'windows-nt)
            (setq expanded (downcase expanded)))
          (when cacheable
            (puthash path expanded project-x--path-key-cache))
          expanded))))

(defun project-x--directory-key (path)
  "Return normalized directory PATH for prefix comparisons."
  (file-name-as-directory (project-x--path-key path)))

(defun project-x--same-file-p (a b)
  "Return non-nil when A and B identify the same path."
  (string-equal (project-x--path-key a) (project-x--path-key b)))

(defun project-x--read-recent-project-files ()
  "Load and return recently activated project-x project files."
  (unless project-x--recent-projects-loaded
    (setq project-x--recent-projects-loaded t)
    (setq project-x--recent-project-files
          (when (file-readable-p project-x-recent-projects-file)
            (condition-case err
                (with-temp-buffer
                  (insert-file-contents project-x-recent-projects-file)
                  (seq-filter #'stringp (read (current-buffer))))
              (end-of-file nil)
              (error
               (display-warning
                'project-x
                (format "Cannot read recent project-x projects from %s: %s"
                        project-x-recent-projects-file
                        (error-message-string err))
                :warning)
               nil)))))
  project-x--recent-project-files)

(defun project-x--write-recent-project-files ()
  "Persist recently activated project-x project files."
  (make-directory (file-name-directory project-x-recent-projects-file) t)
  (with-temp-file project-x-recent-projects-file
    (let ((print-length nil)
          (print-level nil))
      (prin1 project-x--recent-project-files (current-buffer))
      (insert "\n"))))

(defun project-x--remember-project-file (projx-file)
  "Record PROJX-FILE as the most recently activated project-x project."
  (project-x--read-recent-project-files)
  (let ((file (expand-file-name projx-file)))
    (setq project-x--recent-project-files
          (cons file
                (seq-remove (lambda (entry)
                              (project-x--same-file-p entry file))
                            project-x--recent-project-files)))
    (project-x--write-recent-project-files)))

(defun project-x--recent-project-candidates ()
  "Return readable recent project-x files, pruning stale entries."
  (let* ((recent (project-x--read-recent-project-files))
         (available (seq-filter (lambda (file)
                                  (and (project-x--project-file-p file)
                                       (file-readable-p file)))
                                recent)))
    (unless (equal available recent)
      (setq project-x--recent-project-files available)
      (project-x--write-recent-project-files))
    available))

(defun project-x--make-project (projx-file data)
  "Create a project-x project object from PROJX-FILE and DATA."
  (let* ((file (expand-file-name projx-file))
         (root (file-name-directory file))
         (name (or (project-x--hash-get data "name")
                   (file-name-base file))))
    `(project-x :file ,file :root ,(project-x--as-directory root)
                :name ,name :data ,data)))

(defun project-x--project-plist (project)
  "Return PROJECT plist."
  (cdr project))

(defun project-x-file (project)
  "Return PROJECT .projx file path."
  (plist-get (project-x--project-plist project) :file))

(defun project-x-root (project)
  "Return PROJECT root directory."
  (plist-get (project-x--project-plist project) :root))

(defun project-x-name (project)
  "Return PROJECT name."
  (plist-get (project-x--project-plist project) :name))

(defun project-x-data (project)
  "Return PROJECT parsed JSON data."
  (plist-get (project-x--project-plist project) :data))

(defun project-x-load (projx-file)
  "Load PROJX-FILE and return a project-x project object."
  (let* ((file (expand-file-name projx-file))
         (attrs (file-attributes file))
         (mtime (file-attribute-modification-time attrs))
         (cached (gethash file project-x--project-cache)))
    (if (and cached (equal (car cached) mtime))
        (cdr cached)
      (let* ((data (project-x--json-read-file file))
             (project (project-x--make-project file data)))
        (puthash file (cons mtime project) project-x--project-cache)
        (project-x--clear-project-derived-caches file)
        project))))

(defun project-x--clear-project-derived-caches (project-or-file)
  "Clear derived caches for PROJECT-OR-FILE."
  (let ((file (if (stringp project-or-file)
                  project-or-file
                (project-x-file project-or-file))))
    (remhash file project-x--files-cache)
    (remhash file project-x--include-dirs-cache)
    (remhash file project-x--compile-metadata-cache)
    (remhash file project-x--source-dirs-cache)
    (remhash file project-x--membership-cache)
    (clrhash project-x--projects-for-file-cache)))

(defun project-x--expand-path (project path &optional base)
  "Expand PATH for PROJECT.
Relative paths are resolved against BASE, or the project root."
  (let ((base-dir (or base (project-x-root project))))
    (cond
     ((not (stringp path)) nil)
     ((file-name-absolute-p path) (expand-file-name path))
     ((string-prefix-p "~" path) (expand-file-name path))
     (t (expand-file-name path base-dir)))))

(defun project-x--imports (project)
  "Return PROJECT imports as a list of hash tables."
  (let ((imports (project-x--hash-get (project-x-data project) "imports")))
    (cond
     ((vectorp imports) (append imports nil))
     ((listp imports) imports)
     (t nil))))

(defun project-x--msbuild-extractor (configured)
  "Return an executable path for CONFIGURED MSBuild extractor."
  (or (and configured (executable-find configured))
      (and configured (file-executable-p configured) configured)
      (and (file-executable-p project-x--default-msbuild-extractor-path)
           project-x--default-msbuild-extractor-path)
      configured
      project-x-msbuild-extractor-executable))

(defun project-x--compile-command-files (compile-commands &optional entries)
  "Return file entries from COMPILE-COMMANDS, reusing parsed ENTRIES if supplied."
  (when (and compile-commands (file-readable-p compile-commands))
    (let ((entries (or entries (project-x--json-read-file compile-commands))))
      (seq-uniq
       (delq nil
             (mapcar (lambda (entry)
                       (let ((file (project-x--hash-get entry "file")))
                         (and (stringp file) (expand-file-name file))))
                     (append entries nil)))))))

(defun project-x--compile-command-arguments (entry)
  "Return command-line arguments from compile command ENTRY."
  (let ((arguments (project-x--hash-get entry "arguments"))
        (command (project-x--hash-get entry "command")))
    (cond
     ((vectorp arguments) (append arguments nil))
     ((listp arguments) arguments)
     ((stringp command) (split-string-and-unquote command))
     (t nil))))

(defun project-x--include-argument-path (arg next)
  "Return include path from ARG, using NEXT for split -I forms."
  (cond
   ((or (string= arg "-I") (string= arg "/I")) next)
   ((string-prefix-p "-I" arg) (substring arg 2))
   ((string-prefix-p "/I" arg) (substring arg 2))
   ((string-prefix-p "/external:I" arg) (substring arg (length "/external:I")))
   (t nil)))

(defun project-x--compile-command-include-dirs (compile-commands &optional entries)
  "Return include dirs from COMPILE-COMMANDS, reusing parsed ENTRIES if supplied."
  (when (and compile-commands (file-readable-p compile-commands))
    (let* ((entries (or entries (project-x--json-read-file compile-commands)))
           dirs)
      (dolist (entry (append entries nil))
        (let ((args (project-x--compile-command-arguments entry)))
          (while args
            (let* ((arg (car args))
                   (next (cadr args))
                   (path (and (stringp arg)
                              (project-x--include-argument-path arg next))))
              (when (and path (not (string-empty-p path)))
                (push path dirs)))
            (setq args (cdr args)))))
      (seq-filter
       #'file-directory-p
       (seq-uniq
        (mapcar (lambda (path)
                  (file-name-as-directory (expand-file-name path)))
                (seq-uniq dirs)))))))

(defun project-x--import-compile-commands-path (project import)
  "Return configured compile_commands.json path for PROJECT IMPORT."
  (let* ((compile-commands (project-x--hash-get import "compileCommands"))
         (path (and compile-commands
                    (project-x--expand-path project compile-commands))))
    path))

(defun project-x--import-compile-commands-file (project import)
  "Return existing compile_commands.json path for PROJECT IMPORT."
  (let ((path (project-x--import-compile-commands-path project import)))
    (and path (file-exists-p path) path)))

(defun project-x--import-project-files-path (project import)
  "Return generated Visual Studio project file list path for PROJECT IMPORT."
  (let* ((configured (project-x--hash-get import "projectFiles"))
         (solution (project-x--hash-get import "path"))
         (base-name (if (stringp solution)
                        (file-name-base solution)
                      (project-x-name project))))
    (project-x--expand-path
     project
     (or configured
         (format ".project-x/%s/%s-files.json"
                 (project-x-name project)
                 base-name)))))

(defun project-x--import-project-files-file (project import)
  "Return existing generated Visual Studio project file list for PROJECT IMPORT."
  (let ((path (project-x--import-project-files-path project import)))
    (and path (file-exists-p path) path)))

(defun project-x-compile-commands-files (project)
  "Return all compile_commands.json paths referenced by PROJECT."
  (delq nil
        (mapcar (lambda (import)
                  (project-x--import-compile-commands-file project import))
                (project-x--imports project))))

(defun project-x-project-files-files (project)
  "Return generated project item list paths referenced by PROJECT."
  (delq nil
        (mapcar (lambda (import)
                  (project-x--import-project-files-file project import))
                (project-x--imports project))))

(defun project-x--imported-compile-metadata (project)
  "Return cached source files and include dirs from PROJECT compilation databases."
  (let* ((projx (project-x-file project))
         (cached (gethash projx project-x--compile-metadata-cache)))
    (or cached
        (let (files dirs)
          (dolist (database (seq-uniq (project-x-compile-commands-files project)))
            (let ((entries (project-x--json-read-file database)))
              (push (project-x--compile-command-files database entries) files)
              (push (project-x--compile-command-include-dirs database entries)
                    dirs)))
          (setq cached
                (list :files (seq-uniq (apply #'append (nreverse files)))
                      :include-dirs (seq-uniq (apply #'append (nreverse dirs)))))
          (puthash projx cached project-x--compile-metadata-cache)
          cached))))

(defun project-x--explicit-files (project)
  "Return explicit files from PROJECT."
  (let ((files (project-x--string-list
                (project-x--hash-get (project-x-data project) "files"))))
    (delq nil
          (mapcar (lambda (file)
                    (let ((expanded (project-x--expand-path project file)))
                      (and expanded (file-exists-p expanded) expanded)))
                  files))))

(defun project-x--folder-files (project)
  "Return files under PROJECT folders."
  (let ((folders (project-x--string-list
                  (project-x--hash-get (project-x-data project) "folders"))))
    (seq-mapcat (lambda (folder)
                  (project-x--directory-files-recursive
                   (project-x--expand-path project folder)))
                folders)))

(defun project-x--generated-project-files (project-files)
  "Return file entries from generated PROJECT-FILES."
  (when (and project-files (file-readable-p project-files))
    (seq-uniq
     (delq nil
           (mapcar (lambda (file)
                    (and (stringp file)
                         (let ((expanded (expand-file-name file)))
                           (and (file-exists-p expanded) expanded))))
                  (project-x--string-list
                   (project-x--json-read-file project-files)))))))

(defun project-x--all-files (project)
  "Return all files for PROJECT."
  (let* ((projx (project-x-file project))
         (cached (gethash projx project-x--files-cache)))
    (or cached
        (let ((files (seq-uniq
                      (append
                       (project-x--explicit-files project)
                       (project-x--folder-files project)
                       (seq-mapcat #'project-x--generated-project-files
                                   (project-x-project-files-files project))
                       (plist-get (project-x--imported-compile-metadata project)
                                  :files)))))
          (puthash projx files project-x--files-cache)
          files))))

(defun project-x--all-source-dirs (project)
  "Return directories that contain files known to PROJECT."
  (let* ((projx (project-x-file project))
         (cached (gethash projx project-x--source-dirs-cache)))
    (or cached
        (let ((dirs (seq-uniq
                    (delq nil (mapcar #'file-name-directory
                                       (project-x--all-files project))))))
          (puthash projx dirs project-x--source-dirs-cache)
          dirs))))

(defun project-x--all-include-dirs (project)
  "Return all include directories for PROJECT."
  (let* ((projx (project-x-file project))
         (cached (gethash projx project-x--include-dirs-cache)))
    (or cached
        (let ((dirs (plist-get (project-x--imported-compile-metadata project)
                               :include-dirs)))
          (puthash projx dirs project-x--include-dirs-cache)
          dirs))))

(defun project-x--membership-data (project)
  "Return normalized membership data for PROJECT."
  (let* ((projx (project-x-file project))
         (cached (gethash projx project-x--membership-cache)))
    (or cached
        (let ((files (make-hash-table :test 'equal))
             (source-dirs (mapcar #'project-x--directory-key
                                  (project-x--all-source-dirs project)))
             (folder-dirs
              (delq nil
                    (mapcar (lambda (folder)
                              (when-let* ((path (project-x--expand-path
                                                 project folder)))
                                (project-x--directory-key path)))
                            (project-x--string-list
                             (project-x--hash-get
                              (project-x-data project) "folders")))))
             (include-dirs (mapcar #'project-x--directory-key
                                   (project-x--all-include-dirs project))))
          (dolist (file (project-x--all-files project))
           (puthash (project-x--path-key file) t files))
          (setq cached
               (list :root (project-x--directory-key (project-x-root project))
                     :files files
                     :source-dirs source-dirs
                     :folder-dirs folder-dirs
                     :include-dirs include-dirs
                     :contains (make-hash-table :test 'equal)
                     :contains-include (make-hash-table :test 'equal)))
          (puthash projx cached project-x--membership-cache)
          cached))))

(defun project-x--file-in-project-p (file project &optional include-dirs)
  "Return non-nil if FILE belongs to PROJECT.
Primary membership covers project files, folders, and imported project
items.  With INCLUDE-DIRS non-nil, also accept files that are only
reachable through compiler include directories, such as SDK headers
opened by definition jumps."
  (when (and (stringp file) project)
    (let* ((expanded (project-x--path-key file))
          (membership (project-x--membership-data project))
          (contains (plist-get membership (if include-dirs
                                              :contains-include
                                            :contains)))
          (cached (gethash expanded contains project-x--cache-miss)))
      (if (not (eq cached project-x--cache-miss))
          cached
        (puthash expanded
                (or (string-prefix-p (plist-get membership :root) expanded)
                    (gethash expanded (plist-get membership :files))
                    (seq-some (lambda (dir)
                                (string-prefix-p dir expanded))
                              (plist-get membership :source-dirs))
                    (seq-some (lambda (dir)
                                (string-prefix-p dir expanded))
                              (plist-get membership :folder-dirs))
                    (and include-dirs
                         (seq-some (lambda (dir)
                                     (string-prefix-p dir expanded))
                                   (plist-get membership :include-dirs))))
                contains)))))

(defun project-x--known-projects ()
  "Return all loaded project-x projects."
  (let (projects)
    (when project-x--active-project
      (push project-x--active-project projects))
    (maphash (lambda (_file cached)
               (when-let* ((project (cdr-safe cached)))
                 (push project projects)))
             project-x--project-cache)
    (seq-uniq projects
              (lambda (a b)
                (string-equal (project-x-file a) (project-x-file b))))))

(defun project-x--projects-for-file (file &optional include-dirs)
  "Return loaded project-x projects that contain FILE.
INCLUDE-DIRS extends membership to compiler include directories."
  (when (stringp file)
    (let* ((key (cons (project-x--path-key file) (and include-dirs t)))
           (cached (gethash key project-x--projects-for-file-cache
                           project-x--cache-miss)))
      (if (not (eq cached project-x--cache-miss))
          cached
        (puthash key
                 (seq-filter (lambda (project)
                              (project-x--file-in-project-p file project
                                                            include-dirs))
                            (project-x--known-projects))
                 project-x--projects-for-file-cache)))))

(defun project-x--single-project-for-file (file)
  "Return the only loaded project-x project containing FILE.
Return nil when FILE belongs to no loaded project or to multiple projects."
  (let ((projects (project-x--projects-for-file file)))
    (and (= (length projects) 1)
         (car projects))))

(defun project-x--project-display-name (project)
  "Return a completion display name for PROJECT."
  (format "%s - %s" (project-x-name project) (project-x-file project)))

(defun project-x--read-project-for-file (file)
  "Read a project-x project containing FILE from minibuffer."
  (let ((projects (project-x--projects-for-file file t)))
    (pcase projects
      ('nil
       (user-error "No loaded project-x project contains this file"))
      (`(,project)
       project)
      (_
       (let* ((choices (mapcar (lambda (project)
                                (cons (project-x--project-display-name project)
                                      project))
                              projects))
              (choice (completing-read "Project-x context: " choices nil t)))
         (cdr (assoc choice choices)))))))

(defun project-x--preferred-project-for-file (file)
  "Return the preferred project-x project for FILE.
Buffer context and definition-jump context accept include-directory
membership so that SDK headers keep the originating project.  Automatic
context from the active project only accepts primary project files."
  (or (and project-x-buffer-project
           (or (not (stringp file))
              (project-x--file-in-project-p file project-x-buffer-project t))
           project-x-buffer-project)
      (and project-x--context-project
           (stringp file)
           (project-x--file-in-project-p file project-x--context-project t)
           project-x--context-project)
      (and project-x--active-project
           (stringp file)
           (project-x--file-in-project-p file project-x--active-project)
           project-x--active-project)
      (project-x--single-project-for-file file)))

(defun project-x-current-project ()
  "Return the project-x project for the current buffer."
  (or project-x-buffer-project
      (let ((project (project-x--preferred-project-for-file buffer-file-name)))
        (when project
          (project-x--set-buffer-project project))
        project)))

(defun project-x--set-buffer-project (project)
  "Associate PROJECT with the current buffer."
  (setq-local project-x-buffer-project project)
  (project-x--refresh-mode-line-cache t)
  (when project
    (project-x--apply-lsp-args project))
  (force-mode-line-update))

(defun project-x--ensure-buffer-project ()
  "Ensure the current buffer has a project-x project when one can be inferred."
  (or (project-x-current-project)
      (project-x--refresh-mode-line-cache)))

(defun project-x--auto-lsp-file-p ()
  "Return non-nil when current buffer should auto-start LSP for project-x."
  (when-let* ((project (project-x-current-project)))
    (and buffer-file-name
         (memq major-mode project-x-auto-lsp-modes)
         (or (not project-x-auto-lsp-strict-membership)
             (project-x--file-in-project-p buffer-file-name project t)))))

(defun project-x-maybe-start-lsp ()
  "Start LSP in project-x C/C++ buffers only."
  (when (and (project-x--auto-lsp-file-p)
             (fboundp 'lsp-deferred)
             (not (bound-and-true-p lsp-mode)))
    (project-x--apply-lsp-args (project-x-current-project))
    (lsp-deferred)))

(defun project-x--mode-line-string ()
  "Return compact project status text for the mode-line."
  project-x--cached-mode-line-string)

(defun project-x--short-directory-name (directory)
  "Return a short display name for DIRECTORY."
  (when (stringp directory)
    (file-name-nondirectory (directory-file-name directory))))

(defun project-x--projectile-status-name ()
  "Return current Projectile project display name."
  (when (fboundp 'projectile-project-root)
    (project-x--short-directory-name
     (ignore-errors (projectile-project-root)))))

(defun project-x--build-mode-line-string ()
  "Build cached project status text for the current buffer."
  (let* ((project project-x-buffer-project)
         (projectile (and (not project)
                          (project-x--projectile-status-name)))
         (items (delq nil
                      (list
                       (and project (format "ProjX[%s]" (project-x-name project)))
                       (and projectile (format "Projectile[%s]" projectile))))))
    (if items
        (concat " " (string-join items " "))
      "")))

(defun project-x--refresh-mode-line-cache (&optional force)
  "Refresh cached project-x mode-line text for the current buffer."
  (let ((state (list buffer-file-name default-directory
                     project-x-buffer-project project-x--active-project)))
    (when (or force (not (equal state project-x--mode-line-cache-state)))
      (setq-local project-x--mode-line-cache-state state)
      (setq-local project-x--cached-mode-line-string
                  (project-x--build-mode-line-string))
      (setq-local project-x-mode-line-string
                  project-x--cached-mode-line-string))))

(defun project-x--refresh-current-buffer-mode-line-cache ()
  "Refresh cached project-x mode-line text for the current buffer if needed."
  (project-x--refresh-mode-line-cache))

(defun project-x--with-context-project (orig-fun &rest args)
  "Call ORIG-FUN with the current project-x project available to new buffers.
Also attach the context project to the destination buffer, because
revisiting an already open buffer does not run `find-file-hook'."
  (let* ((context (project-x-current-project))
         (project-x--context-project context))
    (prog1 (apply orig-fun args)
      (when (and context
                 (not project-x-buffer-project)
                 buffer-file-name
                 (project-x--file-in-project-p buffer-file-name context t))
        (project-x--set-buffer-project context)
        (project-x-maybe-start-lsp)))))

(defun project-x--with-current-lsp-args (orig-fun &rest args)
  "Apply current buffer's project-x LSP settings before calling ORIG-FUN."
  (when-let* ((project (project-x-current-project)))
    (project-x--apply-lsp-args project))
  (apply orig-fun args))

(defun project-x--lsp-project-for-file (file)
  "Return the project-x project LSP should use for FILE."
  (when (stringp file)
    (project-x--preferred-project-for-file file)))

(defun project-x--lsp-root-for-file (&optional file)
  "Return the project-x LSP root for FILE or the current buffer."
  (when-let* ((target (or file buffer-file-name))
              (_ (stringp target))
              (project (project-x--lsp-project-for-file target)))
    (project-x-root project)))

(defun project-x--lsp-suggest-project-root (orig-fun &rest args)
  "Prefer project-x root over Projectile when lsp-mode asks for a root."
  (or (project-x--lsp-root-for-file)
      (apply orig-fun args)))

(defun project-x--lsp-calculate-root (orig-fun session file-name)
  "Prefer project-x root for FILE-NAME when lsp-mode calculates a root."
  (when (stringp file-name)
    (or (project-x--lsp-root-for-file file-name)
        (funcall orig-fun session file-name))))

(defun project-x--lsp-find-session-folder (orig-fun session file-name)
  "Find project-x session folder for FILE-NAME even when it is external."
  (when (stringp file-name)
    (let ((root (project-x--lsp-root-for-file file-name)))
      (if (and root (member root (lsp-session-folders session)))
          root
        (funcall orig-fun session file-name)))))

(defun project-x--lsp-workspace-root (orig-fun &rest args)
  "Return project-x workspace root for PATH when available."
  (let ((path (car args)))
    (cond
     ((and path (not (stringp path)))
      nil)
     (t
      (or (project-x--lsp-root-for-file path)
          (apply orig-fun args))))))

(defun project-x--lsp-headerline-path-up-to-project (orig-fun &rest args)
  "Skip lsp headerline path breadcrumbs for project-x external files."
  (let ((root (and (fboundp 'lsp-headerline--workspace-root)
                   (lsp-headerline--workspace-root)))
        (file buffer-file-name))
    (if (and (stringp root)
             (stringp file)
             (not (file-equal-p root file))
             (not (file-in-directory-p file root)))
        ""
      (apply orig-fun args))))

(defun project-x--advice-add-once (symbol where function)
  "Add FUNCTION advice to SYMBOL at WHERE unless it is already present."
  (unless (advice-member-p function symbol)
    (advice-add symbol where function)))

(defun project-x-try-current (dir)
  "Return active or nearby project-x project for DIR."
  (let ((file (expand-file-name dir)))
    (cond
     ((project-x--preferred-project-for-file file))
     ((project-x--project-file-p file)
     (project-x-load file))
     (t
      (let ((projx-dir (locate-dominating-file file
                                               (lambda (candidate)
                                                 (directory-files candidate nil
                                                                  (concat (regexp-quote project-x-file-extension)
                                                                          "\\'")
                                                                  t)))))
        (when projx-dir
          (let ((projx (car (directory-files projx-dir t
                                             (concat (regexp-quote project-x-file-extension)
                                                     "\\'")
                                             t))))
            (and projx (project-x-load projx)))))))))

;;; project.el backend

(cl-defmethod project-root ((project (head project-x)))
  "Return project-x PROJECT root."
  (project-x-root project))

(cl-defmethod project-name ((project (head project-x)))
  "Return project-x PROJECT name."
  (project-x-name project))

(cl-defmethod project-files ((project (head project-x)) &optional dirs)
  "Return files in project-x PROJECT, optionally filtered by DIRS."
  (let ((files (project-x--all-files project)))
    (if (not dirs)
        files
      (seq-filter (lambda (file)
                    (seq-some (lambda (dir)
                                (string-prefix-p (project-x--directory-key dir)
                                                 (project-x--path-key file)))
                              dirs))
                  files))))

(cl-defmethod project-external-roots ((project (head project-x)))
  "Return external roots for PROJECT."
  (seq-uniq
   (delq nil
         (append
          (mapcar (lambda (folder) (project-x--as-directory
                                    (project-x--expand-path project folder)))
                  (project-x--string-list
                   (project-x--hash-get (project-x-data project) "folders")))
          (mapcar #'file-name-directory (project-x--all-files project))))
   #'string-equal))

;;; Commands

(defun project-x-activate (project)
  "Activate PROJECT as the current project-x project."
  (setq project-x--active-project project)
  (project-x--set-buffer-project project)
  (project-remember-project project)
  (project-x--remember-project-file (project-x-file project))
  (project-x--apply-lsp-args project)
  (message "Activated project-x project: %s" (project-x-name project))
  (force-mode-line-update t)
  project)

(defun project-x--apply-lsp-args (project)
  "Apply LSP settings for PROJECT before starting clangd."
  (when-let* ((compile-db (car (project-x-compile-commands-files project))))
    (setq lsp-clients-clangd-args
          (list "--header-insertion-decorators=0"
                (concat "--compile-commands-dir="
                        (file-name-directory compile-db))))))

;;;###autoload
(defun project-x-open (projx-file)
  "Open PROJX-FILE as a project-x project."
  (interactive "fProject-x file: ")
  (let ((project (project-x-load projx-file)))
    (project-x-activate project)
    (dired (project-x-root project))
    (project-x--set-buffer-project project)))

(defun project-x-open-recent ()
  "Open a recently activated project-x project."
  (interactive)
  (let* ((files (project-x--recent-project-candidates))
         (choices
          (mapcar (lambda (file)
                    (let ((project (project-x-load file)))
                      (cons (project-x--project-display-name project) file)))
                  files)))
    (unless choices
      (user-error "No recent project-x projects"))
    (project-x-open
     (cdr (assoc (completing-read "Recent project-x: " choices nil t)
                 choices)))))

(defun project-x-close ()
  "Deactivate the active project-x project and detach its buffers.

Existing LSP sessions continue running.  Restarting LSP is only necessary
when a buffer must use a different project-x compile context."
  (interactive)
  (unless project-x--active-project
    (user-error "No active project-x project"))
  (let* ((project project-x--active-project)
         (name (project-x-name project)))
    (setq project-x--active-project nil)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (eq project-x-buffer-project project)
          (setq-local project-x-buffer-project nil)
          (project-x--refresh-mode-line-cache t))))
    (force-mode-line-update t)
    (message "Closed project-x project: %s" name)))

(defun project-x--read-active-project ()
  "Return the active project-x project, or ask for one."
  (or (project-x-current-project)
      (project-x-load (read-file-name "Project-x file: " nil nil t nil
                                      (lambda (file)
                                        (or (file-directory-p file)
                                            (project-x--project-file-p file)))))))

;;;###autoload
(defun project-x-find-file ()
  "Find a file in the active project-x project."
  (interactive)
  (let* ((project (project-x--read-active-project))
         (file (completing-read "Find file: "
                                (project--file-completion-table
                                 (project-files project))
                                nil t)))
    (let ((existing (get-file-buffer file)))
      (find-file file)
      (if (and existing project-x-buffer-project)
          (project-x--apply-lsp-args project-x-buffer-project)
        (project-x--set-buffer-project project)))))

;;;###autoload
(defun project-x-switch-buffer-project ()
  "Select the project-x project for the current buffer."
  (interactive)
  (unless buffer-file-name
    (user-error "Current buffer is not visiting a file"))
  (let ((project (project-x--read-project-for-file buffer-file-name)))
    (when (and (bound-and-true-p lsp-mode)
               (fboundp 'lsp-disconnect))
      (lsp-disconnect))
    (project-x--set-buffer-project project)
    (when (project-x--auto-lsp-file-p)
      (project-x-maybe-start-lsp))
    (message "Project-x buffer project: %s" (project-x-name project))
    project))

(defun project-x--import-output-path (project import)
  "Return output compile_commands.json path for PROJECT IMPORT."
  (or (project-x--import-compile-commands-path project import)
      (let ((fallback (expand-file-name
                       (format ".project-x/%s/compile_commands.json"
                               (project-x-name project))
                       (project-x-root project))))
        fallback)))

(defun project-x--sln-project-paths (solution)
  "Return Visual Studio project paths referenced by SOLUTION."
  (let ((solution-dir (file-name-directory solution))
        projects)
    (with-temp-buffer
      (insert-file-contents solution)
      (goto-char (point-min))
      (while (re-search-forward
              "^Project(.*) = .*?, \"\\([^\"]+\\)\","
              nil t)
        (let ((path (match-string 1)))
          (when (string-match-p "\\.vcxproj\\'" path)
            (push (expand-file-name path solution-dir) projects)))))
    (seq-uniq (nreverse projects) #'string-equal)))

(defun project-x--vs-project-item-files (project-file)
  "Return files shown by Visual Studio PROJECT-FILE."
  (let ((project-dir (file-name-directory project-file))
        files)
    (when (file-readable-p project-file)
      (with-temp-buffer
        (insert-file-contents project-file)
        (goto-char (point-min))
        (while (re-search-forward
                "<\\([[:alnum:]_.:-]+\\)[[:space:]\n]+[^>]*Include=\"\\([^\"]+\\)\""
                nil t)
          (let ((tag (match-string 1))
                (include (match-string 2)))
            (when (member tag project-x-vs-project-item-tags)
              (let ((file (expand-file-name include project-dir)))
                (when (file-exists-p file)
                  (push file files))))))))
    (seq-uniq (nreverse files) #'string-equal)))

(defun project-x--refresh-vs-project-files (solution output)
  "Write Visual Studio project item files for SOLUTION to OUTPUT."
  (let ((files (seq-mapcat #'project-x--vs-project-item-files
                           (project-x--sln-project-paths solution))))
    (make-directory (file-name-directory output) t)
    (with-temp-file output
      (insert (json-encode (vconcat (seq-uniq files #'string-equal))))
      (goto-char (point-min))
      (when (fboundp 'json-pretty-print-buffer)
        (json-pretty-print-buffer)))
    output))

(defun project-x--compile-command-source (entry database-directory)
  "Resolve ENTRY's source against its working and DATABASE-DIRECTORY."
  (let ((file (project-x--hash-get entry "file"))
        (directory (project-x--hash-get entry "directory")))
    (unless (and (stringp file) (stringp directory))
      (error "Invalid compile command: file and directory must be strings"))
    (expand-file-name file (expand-file-name directory database-directory))))

(defun project-x--c-source-p (file)
  "Return non-nil when FILE has a C or C++ source extension."
  (member (downcase (or (file-name-extension file) ""))
          '("c" "cc" "cpp" "cxx" "c++")))

(defun project-x--bulk-source-includes (file)
  "Read direct literal source includes from FILE, without preprocessing it.
Return plists with :path, :line and :reason.  Conditional and angle-bracket
includes have a reason and must not supply derived compile commands."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (while (re-search-forward "\\\\\r?\n" nil t)
      (replace-match "" t t))
    (goto-char (point-min))
    (when (re-search-forward
           "^[ \t]*#[ \t]*include[^\n]*\\.[cC][^\"<>\n]*[\">]" nil t)
      ;; CC Mode handles comments and C++ raw strings; never run user hooks.
      (delay-mode-hooks (c++-mode))
      (goto-char (point-min))
      (let ((case-fold-search nil)
            (depth 0)
            includes)
        (while (re-search-forward "^[ \t]*#[ \t]*\\([a-z]+\\)\\_>" nil t)
          (let ((directive (match-string-no-properties 1))
                (start (match-beginning 0))
                (rest (buffer-substring-no-properties (match-end 0)
                                                      (line-end-position)))
                (line (line-number-at-pos)))
            (unless (save-excursion (nth 8 (syntax-ppss start)))
              (cond
               ((member directive '("if" "ifdef" "ifndef")) (cl-incf depth))
               ((member directive '("elif" "else"))
                (when (zerop depth)
                  (error "Unmatched #%s in %s:%d" directive file line)))
               ((equal directive "endif")
                (when (zerop depth)
                  (error "Unmatched #endif in %s:%d" file line))
                (cl-decf depth))
               ((and (equal directive "include")
                     (string-match
                      "\\`[ \t]*\\(?:\"\\([^\"]+\\)\"\\|<\\([^>]+\\)>\\)" rest))
                (let* ((quoted (match-string 1 rest))
                       (include (or quoted (match-string 2 rest))))
                  (when (project-x--c-source-p include)
                    (push (list :path (expand-file-name
                                       include (file-name-directory file))
                                :line line
                                :reason (cond
                                         ((> depth 0) "conditional include")
                                         ((not quoted) "angle-bracket include")))
                          includes))))))))
        (unless (zerop depth)
          (error "Unterminated preprocessor conditional in %s" file))
        (nreverse includes)))))

(defun project-x--derive-bulk-command (entry source database-directory)
  "Copy bulk ENTRY for SOURCE, or signal an error if copying is unsafe.
DATABASE-DIRECTORY resolves relative paths.  Only argument arrays with one
standalone source operand are supported; shell commands are never reparsed."
  (let* ((arguments (project-x--hash-get entry "arguments"))
         (args (and (or (vectorp arguments) (listp arguments))
                    (append arguments nil)))
         (owner (project-x--compile-command-source entry database-directory))
         (directory (expand-file-name (gethash "directory" entry)
                                      database-directory))
         (matches 0))
    (unless (and args (seq-every-p #'stringp args))
      (error "Bulk command needs a nonempty string arguments array"))
    (when (seq-some (lambda (arg) (or (string-prefix-p "@" arg)
                                    (string-prefix-p "/Yc" arg))) args)
      (error "Response files and PCH creation commands cannot be copied"))
    (setq args
          (mapcar
           (lambda (arg)
             (if (and (project-x--c-source-p arg)
                      (project-x--same-file-p
                       (expand-file-name arg directory) owner))
                 (progn (cl-incf matches) source)
               arg))
           args))
    (unless (= matches 1)
      (error "Bulk command needs exactly one standalone source operand"))
    (let ((derived (copy-hash-table entry)))
      (puthash "file" source derived)
      (puthash "directory" directory derived)
      (puthash "arguments" (vconcat args) derived)
      (remhash "command" derived)
      (remhash "output" derived)
      derived)))

(defun project-x--augment-bulk-commands (entries database-directory)
  "Supplement ENTRIES with direct bulk-included source commands.
DATABASE-DIRECTORY resolves relative paths.  Return :entries, :added and
:warnings.  Existing commands win; conditional or multiple owners are skipped."
  (unless (vectorp entries)
    (error "Compilation database must be a JSON array"))
  (let ((existing (make-hash-table :test 'equal))
        (owners (make-hash-table :test 'equal))
        additions warnings)
    (seq-doseq (entry entries)
      (puthash (project-x--path-key
                (project-x--compile-command-source entry database-directory))
               t existing))
    (seq-doseq (entry entries)
      (let ((file (project-x--compile-command-source entry database-directory)))
        (when (project-x--c-source-p file)
          (cond
           ((or (file-remote-p file) (not (file-regular-p file))
                (not (file-readable-p file)))
            (push (format "Cannot inspect compiled source: %s" file) warnings))
           (t
            (dolist (include (project-x--bulk-source-includes file))
              (let* ((source (plist-get include :path))
                     (key (project-x--path-key source)))
                (unless (gethash key existing)
                  (let ((candidate (cons entry include)))
                    (cl-pushnew
                     candidate (gethash key owners)
                     :test (lambda (a b)
                             (and (eq (car a) (car b))
                                  (equal (plist-get (cdr a) :reason)
                                         (plist-get (cdr b) :reason))))))))))))))
    (maphash
     (lambda (_key candidates)
       (let* ((include (cdar candidates))
              (source (plist-get include :path))
              (reason
               (cond
                ((length> candidates 1) "multiple or conditional bulk owners")
                ((plist-get include :reason))
                ((or (file-remote-p source) (not (file-regular-p source))
                     (not (file-readable-p source)))
                 "included source is not readable"))))
         (if reason
             (push (format
                    "Skipped %s: %s (%s)" source reason
                    (mapconcat
                     (lambda (candidate)
                       (format "%s:%d"
                               (gethash "file" (car candidate))
                               (plist-get (cdr candidate) :line)))
                     candidates ", "))
                   warnings)
           (condition-case err
               (push (project-x--derive-bulk-command
                      (caar candidates) source database-directory)
                     additions)
             (error
              (push (format "Skipped %s: %s" source (error-message-string err))
                    warnings))))))
     owners)
    (setq additions (nreverse additions))
    (list :entries (vconcat entries additions)
          :added (length additions)
          :warnings (nreverse warnings))))

(defun project-x--refresh-vs-solution-import (project import)
  "Refresh Visual Studio solution IMPORT for PROJECT."
  (let* ((solution (project-x--expand-path project
                                           (project-x--hash-get import "path")))
         (configuration (or (project-x--hash-get import "configuration")
                            project-x-default-configuration))
         (platform (or (project-x--hash-get import "platform")
                       project-x-default-platform))
         (extractor (project-x--msbuild-extractor
                     (or (project-x--hash-get import "msbuildExtractor")
                         project-x-msbuild-extractor-executable)))
         (output (project-x--import-output-path project import))
         (project-files (project-x--import-project-files-path project import))
         (output-dir (file-name-directory output))
         (buffer (get-buffer-create "*project-x-refresh*")))
    (unless (and solution (file-exists-p solution))
      (user-error "Solution does not exist: %s" solution))
    (make-directory output-dir t)
    (make-directory (file-name-directory project-files) t)
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert (format "Running %s\n" extractor)))
    (let (staged-output staged-files complete)
      (unwind-protect
          (progn
            (setq staged-output
                  (make-temp-file (expand-file-name ".project-x-compile-" output-dir)
                                  nil ".json")
                  staged-files
                  (make-temp-file
                   (expand-file-name ".project-x-files-"
                                     (file-name-directory project-files))
                   nil ".json"))
            (let ((status (call-process extractor nil buffer t
                                        "--solution" solution
                                        "-c" configuration
                                        "-a" platform
                                        "-o" staged-output)))
              (unless (and (integerp status) (zerop status))
                (user-error "project-x extractor failed (%s); see %s"
                            status (buffer-name buffer))))
            (let* ((entries (project-x--json-read-file staged-output))
                   (result (project-x--augment-bulk-commands entries output-dir))
                   (warnings (plist-get result :warnings))
                   (coding-system-for-write 'utf-8-unix))
              (with-temp-file staged-output
                (insert (json-encode (plist-get result :entries))))
              (project-x--refresh-vs-project-files solution staged-files)
              (with-current-buffer buffer
                (goto-char (point-max))
                (insert (format "\nBulk commands: added %d; warnings %d\n"
                                (plist-get result :added) (length warnings)))
                (dolist (warning warnings) (insert warning "\n")))
              (rename-file staged-files project-files t)
              (rename-file staged-output output t)
              (setq complete t))
            (project-x--clear-project-derived-caches project)
            (message "Updated %s and %s" output project-files)
            output)
        (dolist (file (list staged-output staged-files))
          (when (and file (file-exists-p file)) (delete-file file)))
        (unless complete
          (with-current-buffer buffer
            (goto-char (point-max))
            (insert "\nRefresh failed; compilation database was not replaced.\n"))
          (display-buffer buffer))))))

(defun project-x--buffer-project-p (project)
  "Return non-nil if the current buffer is associated with PROJECT."
  (and project-x-buffer-project
       (project-x--same-file-p (project-x-file project-x-buffer-project)
                               (project-x-file project))))

(defun project-x--refresh-lsp-workspaces (project)
  "Collect distinct running clangd workspaces in PROJECT's file buffers."
  (when (and project-x-refresh-restart-lsp (featurep 'lsp-mode))
    (let (workspaces)
      (dolist (buffer (buffer-list))
        (with-current-buffer buffer
          (when (and buffer-file-name (project-x--buffer-project-p project))
            (dolist (workspace (lsp-workspaces))
              (let ((process (lsp--workspace-proc workspace)))
                (when (and (eq (lsp--workspace-server-id workspace) 'clangd)
                           (processp process) (process-live-p process))
                  (cl-pushnew workspace workspaces :test #'eq)))))))
      (nreverse workspaces))))

(defun project-x--restart-refresh-workspaces (project workspaces)
  "Request restarts of WORKSPACES after refreshing PROJECT.
Return counts under :requested, :skipped and :failed.  Restart failures
are reported separately from the already published compilation database."
  (let ((requested 0) (skipped 0) (failed 0))
    (with-current-buffer (get-buffer-create "*project-x-refresh*")
      (dolist (workspace workspaces)
        (let* ((process (lsp--workspace-proc workspace))
               (root (lsp--workspace-root workspace))
               (others
                (delq nil
                      (mapcar
                       (lambda (buffer)
                         (when (buffer-live-p buffer)
                           (with-current-buffer buffer
                             (when (and buffer-file-name
                                        (not (project-x--buffer-project-p project)))
                               (buffer-name)))))
                       (lsp--workspace-buffers workspace)))))
          (goto-char (point-max))
          (cond
           ((not (and (processp process) (process-live-p process)))
            (cl-incf skipped)
            (insert (format "LSP skipped: clangd at %s is no longer running.\n" root)))
           ((and others
                 (not (and (not noninteractive)
                           (y-or-n-p
                            (format "Restart clangd at %s? Also affects %d other buffer(s): %s "
                                    root (length others) (string-join others ", "))))))
            (cl-incf skipped)
            (insert (format "LSP skipped: shared clangd at %s (%s).\n"
                            root (string-join others ", "))))
           (t
            (condition-case err
                (progn
                  (lsp-workspace-restart workspace)
                  (cl-incf requested)
                  (goto-char (point-max))
                  (insert (format "LSP restart requested: clangd at %s.\n" root)))
              (error
               (cl-incf failed)
               (let ((text (format "LSP restart failed at %s: %s"
                                   root (error-message-string err))))
                 (goto-char (point-max))
                 (insert text "\n")
                 (display-warning 'project-x text :warning))))))))
      (goto-char (point-max))
      (insert (format "LSP restarts: %d requested; %d skipped; %d failed.\n"
                      requested skipped failed)))
    (list :requested requested :skipped skipped :failed failed)))

;;;###autoload
(defun project-x-refresh (&optional project)
  "Refresh generated metadata for PROJECT or the active project."
  (interactive)
  (let* ((project (or project (project-x--read-active-project)))
         (imports (project-x--imports project))
         (workspaces (project-x--refresh-lsp-workspaces project))
         (outputs nil))
    (with-current-buffer (get-buffer-create "*project-x-refresh*")
      (erase-buffer)
      (insert (format "Refreshing %s\n" (project-x-name project))))
    (dolist (import imports)
      (pcase (project-x--hash-get import "type")
        ("visual-studio-solution"
         (push (project-x--refresh-vs-solution-import project import) outputs))
        (_ nil)))
    (project-x--clear-project-derived-caches project)
    (let ((result (when outputs
                    (project-x--restart-refresh-workspaces project workspaces))))
      (message (concat "project-x DB refresh complete: %d output(s); "
                       "LSP restarts %d requested, %d skipped, %d failed; "
                       "see *project-x-refresh*")
               (length outputs)
               (or (plist-get result :requested) 0)
               (or (plist-get result :skipped) 0)
               (or (plist-get result :failed) 0)))
    (nreverse outputs)))

;;;###autoload
(defun project-x-import-visual-studio-solution
    (solution projx-file name configuration platform)
  "Create PROJX-FILE from Visual Studio SOLUTION."
  (interactive
   (let* ((solution (read-file-name "Solution file: " nil nil t nil
                                    (lambda (file)
                                      (or (file-directory-p file)
                                          (string-match-p "\\.slnx?\\'" file)))))
          (projx-file (read-file-name "Project-x file: " nil nil nil
                                      (concat (file-name-base solution) project-x-file-extension)))
          (name (read-string "Project name: " (file-name-base projx-file)))
          (configuration (read-string "Configuration: " project-x-default-configuration))
          (platform (read-string "Platform: " project-x-default-platform)))
     (list solution projx-file name configuration platform)))
  (let* ((projx-file (expand-file-name projx-file))
         (root (file-name-directory projx-file))
         (compile-db (format ".project-x/%s/compile_commands.json" name))
         (project-files (format ".project-x/%s/%s-files.json"
                                name
                                (file-name-base solution)))
         (data `(("name" . ,name)
                 ("files" . [])
                 ("folders" . [])
                 ("imports" . [,(let ((import (make-hash-table :test 'equal)))
                                  (puthash "type" "visual-studio-solution" import)
                                  (puthash "path" (abbreviate-file-name (expand-file-name solution)) import)
                                  (puthash "configuration" configuration import)
                                  (puthash "platform" platform import)
                                  (puthash "compileCommands" compile-db import)
                                  (puthash "projectFiles" project-files import)
                                  import)]))))
    (make-directory root t)
    (with-temp-file projx-file
      (insert (json-encode data))
      (goto-char (point-min))
      (when (fboundp 'json-pretty-print-buffer)
        (json-pretty-print-buffer)))
    (let ((project (project-x-load projx-file)))
      (project-x-activate project)
      (project-x-refresh project)
      project)))

(defun project-x--maybe-register-backend ()
  "Register project-x with `project-find-functions'."
  (define-key project-x-map (kbd "s") #'project-x-switch-buffer-project)
  (remove-hook 'project-find-functions #'project-x-try-current)
  (add-hook 'project-find-functions #'project-x-try-current)
  (setq global-mode-string
        (delete '(:eval project-x-mode-line-string) global-mode-string))
  (setq global-mode-string
        (delete '(:eval (project-x--mode-line-string)) global-mode-string))
  (unless (member '(:eval (project-x--mode-line-string)) global-mode-string)
    (setq global-mode-string
          (append global-mode-string '((:eval (project-x--mode-line-string))))))
  (add-hook 'find-file-hook #'project-x--ensure-buffer-project)
  (add-hook 'find-file-hook #'project-x-maybe-start-lsp)
  (add-hook 'buffer-list-update-hook
            #'project-x--refresh-current-buffer-mode-line-cache)
  (project-x--advice-add-once 'xref-find-definitions
                              :around #'project-x--with-context-project)
  (project-x--advice-add-once 'xref-find-definitions-other-window
                              :around #'project-x--with-context-project)
  (project-x--advice-add-once 'xref-find-definitions-other-frame
                              :around #'project-x--with-context-project)
  (project-x--advice-add-once 'lsp :around #'project-x--with-current-lsp-args)
  (project-x--advice-add-once 'lsp-deferred
                              :around #'project-x--with-current-lsp-args)
  (project-x--advice-add-once 'lsp--suggest-project-root
                              :around #'project-x--lsp-suggest-project-root)
  (project-x--advice-add-once 'lsp--calculate-root
                              :around #'project-x--lsp-calculate-root)
  (project-x--advice-add-once 'lsp-find-session-folder
                              :around #'project-x--lsp-find-session-folder)
  (project-x--advice-add-once 'lsp-workspace-root
                              :around #'project-x--lsp-workspace-root)
  (with-eval-after-load 'lsp-headerline
    (project-x--advice-add-once 'lsp-headerline--build-path-up-to-project-string
                               :around #'project-x--lsp-headerline-path-up-to-project)))

(project-x--maybe-register-backend)

(provide 'project-x)

;;; project-x.el ends here
