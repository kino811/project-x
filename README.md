# project-x

`project-x` adds file-defined workspace projects to Emacs `project.el`.

A `.projx` file is the project identity. Its directory is the project root, and
the project can include files, folders, and imported build metadata outside that
root. This is useful for large C/C++ workspaces where source files and build
outputs are spread across multiple directories.

## Features

- `.projx` project files backed by Emacs `project.el`.
- File search across explicit files, folders, Visual Studio project items, and
  `compile_commands.json`.
- Visual Studio solution import through an external MSBuild extractor.
- C/C++ `lsp-mode` integration with project-specific `compile_commands.json`.
- Buffer-local project context for shared source files used by multiple
  projects.
- Compact mode-line project status.

## Installation

Add this directory to `load-path` and require `project-x`:

```elisp
(add-to-list 'load-path "~/.emacs.d/site-lisp/project-x")
(require 'project-x)
(global-set-key (kbd "C-c p x") project-x-map)
```

## Commands

Default `project-x-map` bindings:

| Key | Command | Description |
| --- | --- | --- |
| `C-c p x o o` | `project-x-open` | Open and activate a `.projx` project. |
| `C-c p x o p` | `project-x-open-recent` | Reopen a recently activated `.projx` project. |
| `C-c p x c c` | `project-x-close` | Deactivate the active project and detach its buffers. |
| `C-c p x f` | `project-x-find-file` | Find a file in the current project-x project. |
| `C-c p x r` | `project-x-refresh` | Refresh imported build metadata. |
| `C-c p x i` | `project-x-import-visual-studio-solution` | Create a `.projx` from a Visual Studio solution. |
| `C-c p x s` | `project-x-switch-buffer-project` | Select the project-x context for the current buffer. |

Recently activated `.projx` paths are saved in
`project-x-recent-projects-file`, so `C-c p x o p` remains available after
restarting Emacs.

Closing a project-x project does not stop existing LSP sessions. Restart LSP
only when a buffer needs a different compile context.

## `.projx` format

Example:

```json
{
  "name": "example",
  "files": [
    "src/main.cpp"
  ],
  "folders": [
    "include"
  ],
  "imports": [
    {
      "type": "visual-studio-solution",
      "path": "example.sln",
      "configuration": "Debug",
      "platform": "x64",
      "compileCommands": ".project-x/example/compile_commands.json",
      "projectFiles": ".project-x/example/example-files.json"
    }
  ]
}
```

Paths are resolved relative to the `.projx` file unless already absolute.
For Visual Studio imports, `projectFiles` is generated from the `.vcxproj`
items that Visual Studio shows, including files excluded from direct
compilation and therefore absent from `compile_commands.json`.

Imported source files and include directories share one native JSON parse per
compilation database when project metadata is first needed. Only the derived
path lists are cached, not the full compilation database. Include paths are
deduplicated before expansion and filesystem checks, including equivalent
expanded paths. Refresh and `.projx` reload invalidate this metadata together
with the existing membership caches.

## Bulk-build compile commands

`project-x-refresh` supplements the extracted compilation database for source
files directly included by a compiled bulk/unity source. It recognizes literal
quoted includes such as `#include "../src/example.cpp"` without relying on a
particular bulk-file naming convention. Missing individual commands inherit the
bulk command's include paths, macros and forced includes, replacing only the
standalone source argument. Existing individual commands are never overwritten.

This prevents clangd from guessing a PCH-creation command for a source that is
actually built through a bulk file. Each refresh starts from a new extraction;
previously derived commands are not carried over.

The `*project-x-refresh*` buffer reports added commands and warnings. Conditional
source includes, multiple owners, missing sources and angle-bracket source
includes are not guessed. Derivation requires an `arguments` array with exactly
one standalone source operand; command-only entries, response files, PCH-creation
commands and joined source switches such as `/Tpfile.cpp` are reported and left
unchanged. Comments and C++ strings are ignored. Only direct source includes are
expanded, not macro includes, recursively included sources or compiler
include-search paths.

The extractor and postprocessing write staging files. The existing compilation
database is replaced by a same-directory rename only after extraction,
augmentation and project-file generation succeed. Failures before publication
leave the old database in place and clean up the staging files. The project-file
list is published separately; the two files are not a transactional pair.

Derived commands describe a source parsed individually with the bulk build's
options. They do not reproduce declarations or macros contributed by earlier
`.cpp` includes in the bulk file, and do not resolve compiler compatibility
errors. Refresh does not reload this package into a running Emacs.

## LSP behavior

When a project-x C/C++ buffer starts LSP, `project-x` sets clangd's
`--compile-commands-dir` from the current project. The LSP workspace root also
prefers the buffer's project-x root over Projectile or other project roots.

After all imports refresh successfully, `project-x-refresh` restarts each
existing clangd workspace attached to the project's open file buffers once.
The association uses the buffer's `.projx` identity, not its source directory.
Sources and headers sharing a workspace are reconnected by lsp-mode together.
This prevents old diagnostics from surviving a compilation database refresh.
No new servers are started for files without LSP, and unrelated workspaces are
left alone. A failed refresh does not request any restarts.

If a workspace also serves file buffers outside the refreshed project,
confirmation lists the affected buffers. Declining skips that workspace;
batch mode skips shared workspaces without prompting. Restarts are asynchronous:
the refresh report distinguishes requested, skipped and failed restarts from
database publication, notifies restart-call failures, and does not claim that
reanalysis has already completed. Later server startup errors remain in LSP's
own logs. Set `project-x-refresh-restart-lsp` to nil to keep LSP unchanged.

If the same source file belongs to multiple loaded `.projx` projects,
`project-x` keeps a buffer-local project context. Reopening an already open file
with `project-x-find-file` does not overwrite that buffer context. Use
`project-x-switch-buffer-project` to change it explicitly.

Project membership has two levels. Primary membership covers project files,
folders, Visual Studio project items, and `compile_commands.json` entries.
Files that are only reachable through compiler include directories, such as SDK
or third-party headers, are secondary members. Secondary membership applies when
a file is opened through a definition jump, `project-x-find-file`, or
`project-x-switch-buffer-project`, so those buffers keep the originating
project. Opening such a file directly does not attach a project-x context.

## Customization

Important options:

```elisp
(setq project-x-msbuild-extractor-executable "path/to/msbuild-extractor-sample.exe")
(setq project-x-default-configuration "Debug")
(setq project-x-default-platform "x64")
(setq project-x-auto-lsp-strict-membership nil)
(setq project-x-refresh-restart-lsp t)
```

`project-x-auto-lsp-strict-membership` is nil by default so headers opened via
definition jumps can still start LSP even when they are not direct
`compile_commands.json` entries.

## Isolated checks

Run from this directory in a separate Emacs, not by loading development code
into an existing editor:

```powershell
emacs --batch -Q -L . -l project-x-tests.el -f ert-run-tests-batch-and-exit
emacs --batch -Q -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile project-x.el project-x-tests.el
```

Tests use disposable source/database fixtures, a stubbed MSBuild extractor,
and mocked LSP workspaces. They do not restart a real language server.
