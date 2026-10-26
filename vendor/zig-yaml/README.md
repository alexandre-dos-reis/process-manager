# zig-yaml (vendored)

YAML parser for Zig, by Jakub Konka (MIT, see `LICENSE`). Upstream: `zig-yaml`, branch `main`
(version 0.3.0 in `build.zig.zon`), taken from a Codeberg archive supplied by the project owner.

Only `src/` is kept. zpawn imports it as module `yaml` (see `build.zig`) and uses it **in the
client only**: the daemon never parses YAML.

## Local patch (1 line, Zig 0.17)

`src/Parser.zig`, in `parse()`:

```diff
-    try self.errors.init(gpa);
+    self.errors = try ErrorBundle.Wip.init(gpa);
```

`ErrorBundle.Wip.init` is a plain function returning the value in Zig 0.17 (it was an
in-place init in 0.16). Drop this patch when upstream follows.
