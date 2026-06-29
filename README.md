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
| `C-c p x o` | `project-x-open` | Open and activate a `.projx` project. |
| `C-c p x f` | `project-x-find-file` | Find a file in the current project-x project. |
| `C-c p x r` | `project-x-refresh` | Refresh imported build metadata. |
| `C-c p x i` | `project-x-import-visual-studio-solution` | Create a `.projx` from a Visual Studio solution. |
| `C-c p x s` | `project-x-switch-buffer-project` | Select the project-x context for the current buffer. |

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

## LSP behavior

When a project-x C/C++ buffer starts LSP, `project-x` sets clangd's
`--compile-commands-dir` from the current project. The LSP workspace root also
prefers the buffer's project-x root over Projectile or other project roots.

If the same source file belongs to multiple loaded `.projx` projects,
`project-x` keeps a buffer-local project context. Reopening an already open file
with `project-x-find-file` does not overwrite that buffer context. Use
`project-x-switch-buffer-project` to change it explicitly.

## Customization

Important options:

```elisp
(setq project-x-msbuild-extractor-executable "path/to/msbuild-extractor-sample.exe")
(setq project-x-default-configuration "Debug")
(setq project-x-default-platform "x64")
(setq project-x-auto-lsp-strict-membership nil)
```

`project-x-auto-lsp-strict-membership` is nil by default so headers opened via
definition jumps can still start LSP even when they are not direct
`compile_commands.json` entries.
