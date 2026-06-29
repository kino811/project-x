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

(defgroup project-x nil
  "File-defined projects for project.el."
  :group 'project)

(defcustom project-x-file-extension ".projx"
  "File extension used by project-x project files."
  :type 'string
  :group 'project-x)

(defcustom project-x-msbuild-extractor-executable
  (or (executable-find "msbuild-extractor-sample")
      "C:/Users/myjung/tools/bin/msbuild-extractor-sample/msbuild-extractor-sample.exe")
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

(defconst project-x--default-msbuild-extractor-path
  "C:/Users/myjung/tools/bin/msbuild-extractor-sample/msbuild-extractor-sample.exe"
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

(defvar project-x--source-dirs-cache (make-hash-table :test 'equal)
  "Cache of source directories keyed by .projx file path.")

(defvar project-x--membership-cache (make-hash-table :test 'equal)
  "Cache of normalized membership data keyed by .projx file path.")

(defvar project-x--projects-for-file-cache (make-hash-table :test 'equal)
  "Cache of loaded project-x projects keyed by normalized file path.")

(defvar project-x--path-key-cache (make-hash-table :test 'equal)
  "Cache of normalized absolute path keys.")

(defvar project-x-mode-line-string ""
  "Compatibility variable for older project-x mode-line entries.")

(defvar-local project-x--cached-mode-line-string ""
  "Cached project-x mode-line text for the current buffer.")

(defvar-local project-x--mode-line-cache-state nil
  "State used to avoid unnecessary project-x mode-line cache refreshes.")

(defvar-keymap project-x-map
  :doc "Keymap for project-x commands."
  "o" #'project-x-open
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
  (let ((json-object-type 'hash-table)
        (json-array-type 'vector)
        (json-key-type 'string)
        (json-false nil)
        (json-null nil))
    (json-read-file file)))

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

(defun project-x--compile-command-files (compile-commands)
  "Return file entries from COMPILE-COMMANDS."
  (when (and compile-commands (file-readable-p compile-commands))
    (let* ((entries (project-x--json-read-file compile-commands)))
      (seq-uniq
       (delq nil
             (mapcar (lambda (entry)
                       (let ((file (project-x--hash-get entry "file")))
                         (and (stringp file) (expand-file-name file))))
                     (append entries nil)))
       #'string-equal))))

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

(defun project-x--compile-command-include-dirs (compile-commands)
  "Return include directories from COMPILE-COMMANDS."
  (when (and compile-commands (file-readable-p compile-commands))
    (let* ((entries (project-x--json-read-file compile-commands))
           dirs)
      (dolist (entry (append entries nil))
        (let ((args (project-x--compile-command-arguments entry)))
          (while args
            (let* ((arg (car args))
                   (next (cadr args))
                   (path (and (stringp arg)
                              (project-x--include-argument-path arg next))))
              (when (and path (not (string-empty-p path)))
                (push (file-name-as-directory (expand-file-name path)) dirs)))
            (setq args (cdr args)))))
      (seq-uniq (seq-filter #'file-directory-p dirs) #'string-equal))))

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
                   (project-x--json-read-file project-files))))
     #'string-equal)))

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
                       (seq-mapcat #'project-x--compile-command-files
                                   (project-x-compile-commands-files project)))
                      #'string-equal)))
          (puthash projx files project-x--files-cache)
          files))))

(defun project-x--all-source-dirs (project)
  "Return directories that contain files known to PROJECT."
  (let* ((projx (project-x-file project))
         (cached (gethash projx project-x--source-dirs-cache)))
    (or cached
        (let ((dirs (seq-uniq
                    (delq nil (mapcar #'file-name-directory
                                       (project-x--all-files project)))
                    #'string-equal)))
          (puthash projx dirs project-x--source-dirs-cache)
          dirs))))

(defun project-x--all-include-dirs (project)
  "Return all include directories for PROJECT."
  (let* ((projx (project-x-file project))
         (cached (gethash projx project-x--include-dirs-cache)))
    (or cached
        (let ((dirs (seq-uniq
                    (seq-mapcat #'project-x--compile-command-include-dirs
                                (project-x-compile-commands-files project))
                    #'string-equal)))
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
                              (project-x-data project) "folders"))))))
          (dolist (file (project-x--all-files project))
           (puthash (project-x--path-key file) t files))
          (setq cached
               (list :root (project-x--directory-key (project-x-root project))
                     :files files
                     :source-dirs source-dirs
                     :folder-dirs folder-dirs
                     :contains (make-hash-table :test 'equal)))
          (puthash projx cached project-x--membership-cache)
          cached))))

(defun project-x--file-in-project-p (file project)
  "Return non-nil if FILE belongs to PROJECT."
  (when (and (stringp file) project)
    (let* ((expanded (project-x--path-key file))
          (membership (project-x--membership-data project))
          (contains (plist-get membership :contains))
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
                              (plist-get membership :folder-dirs)))
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

(defun project-x--projects-for-file (file)
  "Return loaded project-x projects that contain FILE."
  (when (stringp file)
    (let* ((key (project-x--path-key file))
           (cached (gethash key project-x--projects-for-file-cache
                           project-x--cache-miss)))
      (if (not (eq cached project-x--cache-miss))
          cached
        (puthash key
                 (seq-filter (lambda (project)
                              (project-x--file-in-project-p file project))
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
  (let ((projects (project-x--projects-for-file file)))
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
  "Return the preferred project-x project for FILE without guessing ambiguities."
  (or (and project-x-buffer-project
           (or (not (stringp file))
              (project-x--file-in-project-p file project-x-buffer-project))
           project-x-buffer-project)
      (and project-x--context-project
           (stringp file)
           (project-x--file-in-project-p file project-x--context-project)
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
             (project-x--file-in-project-p buffer-file-name project)))))

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
  "Call ORIG-FUN with the current project-x project available to new buffers."
  (let ((project-x--context-project (project-x-current-project)))
    (apply orig-fun args)))

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
    (with-current-buffer buffer
      (erase-buffer)
      (insert (format "Running %s\n" extractor)))
    (let ((status (call-process extractor nil buffer t
                                "--solution" solution
                                "-c" configuration
                                "-a" platform
                                "-o" output)))
      (if (zerop status)
          (progn
            (project-x--refresh-vs-project-files solution project-files)
            (project-x--clear-project-derived-caches project)
            (message "Updated %s and %s" output project-files)
            output)
        (display-buffer buffer)
        (user-error "project-x refresh failed; see %s" (buffer-name buffer))))))

;;;###autoload
(defun project-x-refresh (&optional project)
  "Refresh generated metadata for PROJECT or the active project."
  (interactive)
  (let* ((project (or project (project-x--read-active-project)))
         (imports (project-x--imports project))
         (outputs nil))
    (dolist (import imports)
      (pcase (project-x--hash-get import "type")
        ("visual-studio-solution"
         (push (project-x--refresh-vs-solution-import project import) outputs))
        (_ nil)))
    (project-x--clear-project-derived-caches project)
    (message "project-x refresh complete: %d output(s)" (length outputs))
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
