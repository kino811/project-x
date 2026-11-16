;;; project-x-tests.el --- Tests for refresh behavior -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'project-x)

(defmacro project-x-test--workspace (&rest body)
  "Run BODY with a disposable directory and isolated path caches."
  (declare (indent 0) (debug t))
  `(let* ((directory (make-temp-file
                     (expand-file-name ".project-x-test-" default-directory) t))
          (default-directory (file-name-as-directory directory))
          (project-x--compile-metadata-cache (make-hash-table :test 'equal))
          (project-x--path-key-cache (make-hash-table :test 'equal)))
     (unwind-protect (progn ,@body)
       (delete-directory directory t))))

(defun project-x-test--write (file text)
  "Write TEXT to FILE, creating its parent directory."
  (make-directory (file-name-directory (expand-file-name file)) t)
  (with-temp-file file (insert text))
  (expand-file-name file))

(defun project-x-test--entry (file &rest arguments)
  "Return a compile entry for FILE with ARGUMENTS."
  (let ((entry (make-hash-table :test 'equal)))
    (puthash "file" file entry)
    (puthash "directory" default-directory entry)
    (puthash "arguments" (vconcat (cons "cl.exe" arguments)) entry)
    entry))

(ert-deftest project-x-test-native-json-preserves-metadata-value-types ()
  (project-x-test--workspace
    (let* ((coding-system-for-write 'utf-8-with-signature)
           (file (project-x-test--write
                  "values.json"
                  (concat "{\"array\":[1,true,false,null,\"\\u03bb\"],"
                          "\"object\":{\"key\":\"value\"},\"empty\":[]}")))
           (data (project-x--json-read-file file)))
      (should (hash-table-p data))
      (should (equal (gethash "array" data)
                     (vector 1 t nil nil (string #x3bb))))
      (should (equal (gethash "key" (gethash "object" data)) "value"))
      (should (equal (gethash "empty" data) []))
      (project-x-test--write "values.json" "{bad json")
      (should-error (project-x--json-read-file file)))))

(ert-deftest project-x-test-membership-shares-parse-and-deduplicates-path-checks ()
  (project-x-test--workspace
    (let* ((unit (project-x-test--write "unit.cpp" "void unit();\n"))
           (include (file-name-as-directory
                     (expand-file-name "include dir")))
           (missing (file-name-as-directory (expand-file-name "missing")))
           (database (expand-file-name "compile_commands.json"))
           (import (make-hash-table :test 'equal))
           (data (make-hash-table :test 'equal))
           (project (project-x--make-project
                     (expand-file-name "example.projx") data))
           (reader (symbol-function 'project-x--json-read-file))
           (directory-p (symbol-function 'file-directory-p))
           (reads 0)
           checks)
      (make-directory include)
      (puthash "compileCommands" database import)
      (puthash "imports" (vector import) data)
      (project-x-test--write
       database
       (json-serialize
        (make-vector
         250 (project-x-test--entry
              unit "-I" "include dir" "/I./include dir/"
              (concat "/external:I" include) "/Imissing" unit))))
      (cl-letf (((symbol-function 'project-x--json-read-file)
                 (lambda (path)
                   (cl-incf reads)
                   (funcall reader path)))
                ((symbol-function 'file-directory-p)
                 (lambda (path)
                   (push path checks)
                   (funcall directory-p path))))
        (should (equal (project-x--all-files project) (list unit)))
        (should (equal (project-x--all-include-dirs project) (list include)))
        (should (project-x--file-in-project-p
                 (expand-file-name "header.h" include) project t))
        (should (= reads 1))
        (should (= (length checks) 2))
        (should (= (cl-count include checks :test #'equal) 1))
        (should (= (cl-count missing checks :test #'equal) 1))
        (let ((other (project-x-test--write "other.cpp" "void other();\n")))
          (project-x-test--write
           database (json-serialize
                     (vector (project-x-test--entry other other))))
          (dolist (target (list (project-x-file project) project))
            (project-x--clear-project-derived-caches target)
            (should (equal (project-x--all-files project) (list other)))
            (should-not (project-x--all-include-dirs project))))
        (should (= reads 3))))))

(ert-deftest project-x-test-bulk-command-preserves-flags-and-existing-entries ()
  (project-x-test--workspace
    (project-x-test--write
     "bulk.cpp" (concat "#include \"source dir/unit.cpp\"\n"
                        "#include \"source dir/./unit.cpp\"\n"
                        "#include \"source dir/direct.cpp\"\n"))
    (let* ((unit (project-x-test--write "source dir/unit.cpp" "void unit() {}\n"))
           (direct (project-x-test--write "source dir/direct.cpp" "void direct() {}\n"))
           (bulk (project-x-test--entry
                  "bulk.cpp" "/Ipath with spaces" "/DANT_TESTBED"
                  "/DMACRO=bulk.cpp" "/Yupch.h" "/FIpch.h" "bulk.cpp"))
           (existing (project-x-test--entry direct "/DDIRECT" direct))
           (original (copy-sequence (gethash "arguments" bulk)))
           result derived)
      (puthash "output" "bulk.obj" bulk)
      (setq result (project-x--augment-bulk-commands
                    (vector bulk existing) directory)
            derived (aref (plist-get result :entries) 2))
      (should (= (plist-get result :added) 1))
      (should-not (plist-get result :warnings))
      (should (eq (aref (plist-get result :entries) 0) bulk))
      (should (eq (aref (plist-get result :entries) 1) existing))
      (should (equal (gethash "arguments" bulk) original))
      (should (equal (gethash "file" derived) unit))
      (should-not (gethash "output" derived))
      (should (equal (gethash "arguments" derived)
                     (vconcat (append (butlast (append original nil)) (list unit))))))))

(ert-deftest project-x-test-bulk-parser-ignores-literals-and-conditional-includes ()
  (project-x-test--workspace
    (project-x-test--write
     "bulk.cpp"
     (concat "/*\n#include \"comment.cpp\"\n*/\n"
             "const char* text = R\"tag(\n\"\n#include \"raw.cpp\"\n)tag\";\n"
             "// continued comment \\\n#include \"continued.cpp\"\n"
             "#if SOME_FLAG\n#if OTHER_FLAG\n#include \"nested.cpp\"\n#endif\n"
             "#else\n#include \"other.cpp\"\n#endif\n"
             "#inc\\\nlude \"real.cpp\"\n"))
    (dolist (name '("comment.cpp" "raw.cpp" "continued.cpp"
                    "nested.cpp" "other.cpp" "real.cpp"))
      (project-x-test--write name "void function();\n"))
    (let ((result (project-x--augment-bulk-commands
                   (vector (project-x-test--entry "bulk.cpp" "bulk.cpp"))
                   directory)))
      (should (= (plist-get result :added) 1))
      (should (equal (gethash "file" (aref (plist-get result :entries) 1))
                     (expand-file-name "real.cpp")))
      (should (= (length (plist-get result :warnings)) 2))
      (should (seq-every-p (lambda (warning)
                            (string-match-p "conditional include" warning))
                          (plist-get result :warnings))))))

(ert-deftest project-x-test-bulk-owners-never-choose-between-configurations ()
  (dolist (conditional '(nil t))
    (project-x-test--workspace
      (project-x-test--write "first.cpp" "#include \"unit.cpp\"\n")
      (project-x-test--write "second.cpp"
                             (if conditional
                                 "#if FLAG\n#include \"unit.cpp\"\n#endif\n"
                               "#include \"unit.cpp\"\n"))
      (project-x-test--write "unit.cpp" "void function();\n")
      (let ((result (project-x--augment-bulk-commands
                     (vector (project-x-test--entry "first.cpp" "/DFIRST" "first.cpp")
                             (project-x-test--entry "second.cpp" "/DSECOND" "second.cpp"))
                     directory)))
        (should (= (plist-get result :added) 0))
        (should (= (length (plist-get result :warnings)) 1))
        (should (string-match-p "multiple.*owners"
                                (car (plist-get result :warnings))))))))

(ert-deftest project-x-test-bulk-counts-each-derived-source-and-is-idempotent ()
  (project-x-test--workspace
    (project-x-test--write "bulk.cpp"
                           "#include \"first.cpp\"\n#include \"second.cpp\"\n")
    (project-x-test--write "first.cpp" "void first();\n")
    (project-x-test--write "second.cpp" "void second();\n")
    (let* ((result (project-x--augment-bulk-commands
                    (vector (project-x-test--entry "bulk.cpp" "bulk.cpp"))
                    directory))
           (entries (plist-get result :entries))
           (again (project-x--augment-bulk-commands entries directory)))
      (should (= (plist-get result :added) 2))
      (should (= (length entries) 3))
      (should (= (plist-get again :added) 0))
      (should (equal (plist-get again :entries) entries))
      (should-not (plist-get again :warnings)))))

(ert-deftest project-x-test-bulk-resolves-relative-command-directory-and-include ()
  (project-x-test--workspace
    (let* ((bulk (project-x-test--write "build dir/bulk.cpp"
                                       "#include \"../src/unit.cpp\"\n"))
           (unit (project-x-test--write "src/unit.cpp" "void function();\n"))
           (entry (project-x-test--entry "bulk.cpp" "/FIpch.h" "bulk.cpp")))
      (puthash "directory" "build dir" entry)
      (let* ((result (project-x--augment-bulk-commands (vector entry) directory))
             (derived (aref (plist-get result :entries) 1)))
        (should (= (plist-get result :added) 1))
        (should-not (plist-get result :warnings))
        (should (equal (gethash "file" derived) unit))
        (should (equal (directory-file-name (gethash "directory" derived))
                       (directory-file-name (file-name-directory bulk))))
        (should (equal (gethash "arguments" derived)
                       (vector "cl.exe" "/FIpch.h" unit)))))))

(ert-deftest project-x-test-bulk-reports-unsafe-or-unresolvable-commands ()
  (dolist (case '(missing angle command-only response pch no-operand))
    (project-x-test--workspace
      (project-x-test--write "bulk.cpp"
                             (if (eq case 'angle)
                                 "#include <unit.cpp>\n"
                               "#include \"unit.cpp\"\n"))
      (unless (eq case 'missing)
        (project-x-test--write "unit.cpp" "void function();\n"))
      (let ((entry (project-x-test--entry "bulk.cpp" "bulk.cpp")))
        (pcase case
          ('command-only
           (remhash "arguments" entry)
           (puthash "command" "cl.exe bulk.cpp" entry))
          ('response (puthash "arguments" ["cl.exe" "@flags.rsp" "bulk.cpp"] entry))
          ('pch (puthash "arguments" ["cl.exe" "/Ycpch.h" "bulk.cpp"] entry))
          ('no-operand (puthash "arguments" ["cl.exe" "/Tpbulk.cpp"] entry)))
        (let ((result (project-x--augment-bulk-commands (vector entry) directory)))
          (should (= (plist-get result :added) 0))
          (should (= (length (plist-get result :warnings)) 1)))))))

(ert-deftest project-x-test-bulk-rejects-malformed-database-or-conditionals ()
  (project-x-test--workspace
    (should-error (project-x--augment-bulk-commands
                   (make-hash-table :test 'equal) directory))
    (dolist (text '("#endif\n#include \"unit.cpp\"\n"
                    "#if FLAG\n#include \"unit.cpp\"\n"))
      (project-x-test--write "bulk.cpp" text)
      (should-error
       (project-x--augment-bulk-commands
        (vector (project-x-test--entry "bulk.cpp" "bulk.cpp")) directory)))))

(ert-deftest project-x-test-refresh-publishes-completed-database-only ()
  (dolist (failure '(nil extractor json metadata))
    (project-x-test--workspace
      (let* ((solution (project-x-test--write "example.sln" "fixture\n"))
             (output (project-x-test--write "compile_commands.json" "old database\n"))
             (items (project-x-test--write "example-files.json" "old files\n"))
             (data (make-hash-table :test 'equal))
             (import (make-hash-table :test 'equal))
             (project (project-x--make-project (expand-file-name "example.projx") data)))
        (puthash "path" solution import)
        (puthash "compileCommands" output import)
        (puthash "projectFiles" items import)
        (project-x-test--write "bulk.cpp" "#include \"unit.cpp\"\n")
        (project-x-test--write "unit.cpp" "void function();\n")
        (cl-letf
            (((symbol-function 'call-process)
              (lambda (_program _infile _destination _display &rest args)
                (let ((staged (cadr (member "-o" args))))
                  (should-not (equal staged output))
                  (should (equal (with-temp-buffer
                                   (insert-file-contents output) (buffer-string))
                                 "old database\n"))
                  (project-x-test--write
                   staged (if (eq failure 'json) "invalid JSON\n"
                            (json-encode
                             (vector (project-x-test--entry "bulk.cpp" "bulk.cpp")))))
                  (if (eq failure 'extractor) 1 0))))
             ((symbol-function 'project-x--refresh-vs-project-files)
              (lambda (_solution staged)
                (when (eq failure 'metadata) (error "Metadata fixture failed"))
                (project-x-test--write staged "[]\n"))))
          (if failure
              (progn
                (should-error (project-x--refresh-vs-solution-import project import))
                (should (equal (with-temp-buffer
                                 (insert-file-contents output) (buffer-string))
                               "old database\n"))
                (should (equal (with-temp-buffer
                                 (insert-file-contents items) (buffer-string))
                               "old files\n")))
            (should (equal (project-x--refresh-vs-solution-import project import) output))
            (let ((entries (project-x--json-read-file output)))
              (should (= (length entries) 2))
              (should (equal (gethash "file" (aref entries 1))
                             (expand-file-name "unit.cpp"))))
            (should (with-current-buffer "*project-x-refresh*"
                      (string-match-p "Bulk commands: added 1; warnings 0"
                                      (buffer-string))))))
        (should-not (directory-files directory nil "\\`\\.project-x-\\(?:compile\\|files\\)-"))))))

(defmacro project-x-test--lsp (&rest body)
  "Run BODY with fake LSP workspaces and disposable file buffers.
The local function `attach' associates a buffer with a project and workspaces."
  (declare (indent 0) (debug t))
  `(cl-progv '(features) (list (cons 'lsp-mode features))
     (let ((project-x-refresh-restart-lsp t)
           buffers associations restarts warnings)
       (unwind-protect
           (cl-letf
               (((symbol-function 'lsp-workspaces)
		 (lambda () (cdr (assq (current-buffer) associations))))
		((symbol-function 'lsp--workspace-server-id)
		 (lambda (ws) (plist-get ws :server)))
		((symbol-function 'lsp--workspace-proc)
		 (lambda (ws) (plist-get ws :process)))
		((symbol-function 'lsp--workspace-root)
		 (lambda (ws) (plist-get ws :root)))
		((symbol-function 'lsp--workspace-buffers)
		 (lambda (ws) (plist-get ws :buffers)))
		((symbol-function 'processp)
		 (lambda (process) (memq process '(live dead))))
		((symbol-function 'process-live-p)
		 (lambda (process) (eq process 'live)))
		((symbol-function 'lsp-workspace-restart)
		 (lambda (ws) (push ws restarts)))
		((symbol-function 'display-warning)
		 (lambda (_type text &rest _args) (push text warnings))))
             (cl-labels
		 ((attach (project file workspaces)
                    (let ((buffer (generate-new-buffer " *project-x-lsp-test*")))
                      (push buffer buffers)
                      (with-current-buffer buffer
			(setq-local buffer-file-name file
                                    project-x-buffer-project project))
                      (push (cons buffer workspaces) associations)
                      (dolist (ws workspaces)
			(plist-put ws :buffers (cons buffer (plist-get ws :buffers))))
                      buffer)))
               ,@body))
	 (dolist (buffer buffers) (kill-buffer buffer))))))

(defun project-x-test--lsp-workspace (&optional server process)
  "Return a fake workspace for SERVER and PROCESS."
  (list :server (or server 'clangd) :process (or process 'live)
        :root default-directory :buffers nil))

(ert-deftest project-x-test-refresh-selects-only-associated-live-clangd-once ()
  (project-x-test--lsp
    (let* ((data (make-hash-table :test 'equal))
           (project (project-x--make-project "one.projx" data))
           (same-project (project-x--make-project "./one.projx" data))
           (other (project-x--make-project "two.projx" data))
           (first (project-x-test--lsp-workspace))
           (second (project-x-test--lsp-workspace))
           (unrelated (project-x-test--lsp-workspace))
           (dead (project-x-test--lsp-workspace 'clangd 'dead))
           (python (project-x-test--lsp-workspace 'pylsp)))
      (attach project "outside/source.cpp" (list first dead python))
      (attach same-project "outside/source.h" (list first second))
      (attach other "outside/source.cpp" (list unrelated))
      (attach nil "outside/source.cpp" (list unrelated))
      (let ((selected (project-x--refresh-lsp-workspaces project)))
        (should (= (length selected) 2))
        (should (memq first selected))
        (should (memq second selected)))
      (let ((project-x-refresh-restart-lsp nil))
        (should-not (project-x--refresh-lsp-workspaces project)))
      (cl-progv '(features) (list (remq 'lsp-mode (copy-sequence features)))
        (should-not (project-x--refresh-lsp-workspaces project)))
      (should-not restarts))))

(ert-deftest project-x-test-refresh-shared-workspace-needs-confirmation ()
  (dolist (case '(decline accept batch))
    (project-x-test--lsp
      (let* ((project (project-x--make-project "one.projx" nil))
             (workspace (project-x-test--lsp-workspace))
             (noninteractive (eq case 'batch))
             prompt)
        (attach project "source.cpp" (list workspace))
        (let ((other (attach nil "other.cpp" (list workspace))))
          (cl-letf (((symbol-function 'y-or-n-p)
                     (lambda (question)
                       (setq prompt question)
                       (eq case 'accept))))
            (let ((result (project-x--restart-refresh-workspaces
                           project (list workspace))))
              (should (= (plist-get result :requested) (if (eq case 'accept) 1 0)))
              (should (= (plist-get result :skipped) (if (eq case 'accept) 0 1)))
              (should (= (length restarts) (if (eq case 'accept) 1 0)))
              (if (eq case 'batch)
                  (should-not prompt)
                (should (string-match-p (regexp-quote (buffer-name other)) prompt))))))))))

(ert-deftest project-x-test-refresh-restart-failure-is-reported-and-does-not-stop-others ()
  (project-x-test--lsp
    (let* ((project (project-x--make-project "one.projx" nil))
           (first (project-x-test--lsp-workspace))
           (second (project-x-test--lsp-workspace))
           (stopped (project-x-test--lsp-workspace 'clangd 'dead)))
      (cl-letf (((symbol-function 'lsp-workspace-restart)
                 (lambda (ws)
                   (if (eq ws first) (error "Restart fixture failed")
                     (push ws restarts)))))
        (let ((result (project-x--restart-refresh-workspaces
                       project (list first second stopped))))
          (should (= (plist-get result :failed) 1))
          (should (= (plist-get result :requested) 1))
          (should (= (plist-get result :skipped) 1))
          (should (equal restarts (list second)))
          (should (string-match-p "Restart fixture failed" (car warnings)))
          (should (with-current-buffer "*project-x-refresh*"
                    (string-match-p "LSP restart requested" (buffer-string)))))))))

(ert-deftest project-x-test-refresh-restarts-only-after-all-imports-succeed ()
  (dolist (failure '(nil first second))
    (let* ((project-x-refresh-restart-lsp t)
           (data (make-hash-table :test 'equal))
           (import (make-hash-table :test 'equal))
           (project (project-x--make-project "one.projx" data))
           (workspace (list 'workspace))
           (imports 0)
           events)
      (puthash "type" "visual-studio-solution" import)
      (puthash "imports" (vector import import) data)
      (cl-letf
          (((symbol-function 'project-x--refresh-lsp-workspaces)
            (lambda (_project)
              (push 'collect events)
              (list workspace)))
           ((symbol-function 'project-x--refresh-vs-solution-import)
            (lambda (_project _import)
              (cl-incf imports)
              (push 'extract events)
              (when (or (and (eq failure 'first) (= imports 1))
                        (and (eq failure 'second) (= imports 2)))
                (error "Import fixture failed"))
              "compile_commands.json"))
           ((symbol-function 'project-x--restart-refresh-workspaces)
            (lambda (_project workspaces)
              (should (equal workspaces (list workspace)))
              (push 'restart events)
              '(:requested 1 :skipped 0 :failed 0))))
        (if failure
            (progn
              (should-error (project-x-refresh project))
              (should-not (memq 'restart events)))
          (should (= (length (project-x-refresh project)) 2))
          (should (equal (nreverse events) '(collect extract extract restart))))
        (setq events nil)
        (puthash "imports" [] data)
        (should-not (project-x-refresh project))
        (should-not (memq 'restart events))))))

(provide 'project-x-tests)
;;; project-x-tests.el ends here
