# Amith.Build

One maintained set of PowerShell build/release tools for .NET libraries, Windows desktop applications, console applications and web APIs. The same implementation is used by local commands, a stage-based GitHub composite action and a reusable workflow.

The intended repository is `Amith211/Amith.Build`. Release tags are created explicitly after validation; these files do not publish releases automatically.

## Quick start: local

Requires PowerShell 7.4+, .NET SDK 8+ (MSBuild 17.8+) compatible with your project, and Git for GitHub releases. Build discovery uses MSBuild's evaluated properties, not raw project XML. The tooling's own validation uses .NET 10.

Import the module from one centrally maintained checkout (or put its `src` directory on your PowerShell module path/profile):

```powershell
Import-Module 'C:/Tools/Amith.Build/src/Amith.Build/Amith.Build.psd1'
```

From a consumer repository, build all projects in its single root solution and package the configured outputs:

```powershell
Invoke-AmithBuild -Version 1.2.3
```

Build the eligible applications for both Windows and Linux:

```powershell
Invoke-AmithBuild -Solution ./MyApp.sln -Version 1.2.3 -Runtimes win-x64,linux-x64
```

For just one project, without describing the rest of its solution:

```powershell
Invoke-AmithBuild -Project ./src/Api/Api.csproj -Version 1.2.3 -Runtimes win-x64,linux-x64
```

`-Project` (alias for `-ProjectPath`) also accepts multiple paths. It selects only those roots, while retaining matching configured settings and overrides. Project-reference dependencies still build normally.

Windows-only applications retain compatible Windows targets. NuGet libraries are packed without a runtime identifier. Ordinary cross-platform applications default to `win-x64` and `linux-x64` when no runtime was explicitly configured or declared. WPF/WinForms applications default to `win-x64`.

The equivalent entry-point script is:

```powershell
& 'C:/Tools/Amith.Build/scripts/Invoke-AmithBuild.ps1' -ConfigPath ./amith.build.psd1 -Version 1.2.3
```

No build scripts need copying into consumer repositories. Updating the shared checkout updates every local consumer that imports it; choose a stable release line or pinned checkout for reproducibility.

## Automatic, hybrid and explicit configuration

The configuration file is optional. It is a data file, not a script with custom executable build code.

When creating a plan, an explicit `-ConfigPath` wins; a missing file is an error. Otherwise discovery checks only these locations under `RootPath`, which defaults to the current working directory:

1. `build/amith.build.psd1` or `Build/amith.build.psd1`.
2. `amith.build.psd1` at the root.
3. No configuration: use automatic discovery and defaults.

On case-insensitive filesystems, `build` and `Build` refer to the same directory. If both distinct directories contain configs on a case-sensitive filesystem, discovery fails with an ambiguity error; select one with `-ConfigPath`. A build-folder config takes precedence over the root config. Files are never merged, and the selected path is printed. Parent directories and other subdirectories are not searched. Supplying `-Solution` does not change the search root.

Automatically discovered configurations resolve project, solution and output paths from `RootPath`, including configs in `build/` or `Build/`: no `Root = '..'` is needed. Explicit `-ConfigPath` preserves the existing default of resolving from the configuration file's directory. In either case, an explicit `Root` setting is resolved relative to the configuration file's directory and overrides that default.

```powershell
# Automatically loads build/amith.build.psd1 when present.
Invoke-AmithBuild -RootPath C:/Projects/MyApp -Version 1.2.3

# Explicit selection preserves config-relative roots.
# Set Root = '..' inside this file to target the repository root.
Invoke-AmithBuild -ConfigPath ./build/amith.build.psd1 -Version 1.2.3
```

### Automatic discovery with exceptions

```powershell
@{
    Solution = 'MyApp.sln'
    Runtimes = @('win-x64', 'linux-x64')
    Exclude = @('samples/**', '**/Scratch.csproj')
    Overrides = @(
        @{ Match = 'src/Contracts/*.csproj'; Pack = $true }
        @{ Match = '**/Client.Tests.csproj'; TestPlatforms = @('Windows') }
        @{ Match = 'src/Api/Api.csproj'; Kind = 'Web'; SelfContained = $false }
    )
}
```

Adding a project to the solution includes it in subsequent plans. Libraries are always classified as `Library`; package creation is an independent `Pack` flag, defaulting to false. Enable it for libraries you distribute. For repositories primarily containing packages, set `Defaults = @{ Pack = $true }`, with per-library exceptions. That default applies only to libraries; tests and applications are not packaged. `Projects` can also supplement discovered projects or override an existing project by path. `Overrides` is an ordered array: later matching entries win. Patterns use `/` separators, `*`, `?` and `**`; a plain project-name pattern is supported too.

Exclusions remove build roots, not MSBuild project-reference dependencies. A referenced dependency can still be built by its parent, as in normal MSBuild. The tooling does not generate a solution filter that pretends those references have disappeared.

### Package selection

Command-line selections operate on exact, case-insensitive project `Name` values from the plan (including configured Name overrides), not paths or patterns. Unknown names and application/test selections are errors.

| Option | Effect |
| --- | --- |
| `-PackProjects 'Sdk','Contracts'` | Add to configured packaging selections. |
| `-PackOnlyProjects 'Sdk','Contracts'` | Replace configured selections with exactly these libraries. |
| `-PackAllLibraries` | Select every eligible library. |
| `-ExcludePackProjects 'InternalHelpers'` | Remove libraries after inclusions/defaults have been applied. |
| `-NoPack` | Disable NuGet package creation; builds, tests and application publishing continue. |

`PackOnlyProjects` cannot be combined with `PackProjects` or `PackAllLibraries`. `NoPack` cannot be combined with any packaging selection option. Exclusions win over inclusions.

```powershell
Invoke-AmithBuild -Version 1.2.3 -PackProjects 'My.Api.Sdk'
Invoke-AmithBuild -Version 1.2.3 -PackOnlyProjects 'My.Api.Sdk','My.Contracts'
Invoke-AmithBuild -Version 1.2.3 -PackAllLibraries -ExcludePackProjects 'InternalHelpers'
Invoke-AmithBuild -Version 1.2.3 -NoPack
```

`IsPackable=false` in an evaluated project prevents packaging. Bulk selection skips such libraries; a final explicit/configured selection requesting one produces an error. The scripts never force `IsPackable=true`.

Selection options create a fresh plan, just like a supplied version or runtime list. Later `-PlanPath ... -Stages ...` calls reuse its stored per-project `Pack` decisions. The plan displays `Pack=true` beside selected libraries. Plans using earlier numeric schema identifiers must be regenerated, and `Kind='NuGet'` configuration must be migrated: use `Kind='Library'; Pack=$true` for previously configured NuGet projects.

### Fully explicit definitions

```powershell
@{
    Discover = $false
    Projects = @(
        @{ Path = 'src/Client/Client.csproj'; Kind = 'Desktop'; Runtimes = @('win-x64') }
        @{ Path = 'src/Api/Api.csproj'; Kind = 'Web'; Runtimes = @('win-x64', 'linux-x64') }
        @{ Path = 'src/Contracts/Contracts.csproj'; Kind = 'Library'; Pack = $true }
        @{ Path = 'tests/Api.Tests/Api.Tests.csproj'; Kind = 'Test' }
    )
}
```

Explicit project definitions are also available through the `-Projects` API parameter. Examples for automatic discovery, NuGet, desktop/API and explicit builds are in `examples/`.

### Configuration reference

| Setting | Purpose |
| --- | --- |
| `Root` | Explicit repository root relative to the configuration file. When omitted, automatic discovery retains `RootPath`; explicit `-ConfigPath` uses the file's directory. |
| `Solution` | Explicit `.sln`/`.slnx`. Multiple root solutions require a choice. |
| `Discover` | Defaults to true. Set false to use only `Projects`. |
| `Configuration` | Defaults to Release. |
| `Version` | Optional configured SemVer; a CLI version wins. |
| `Runtimes` | Global application targets. Per-project runtimes take precedence. |
| `Output` | Artifact base directory; defaults to `artifacts`. |
| `Exclude` | Project path/name patterns. |
| `Defaults` | Default per-project options, applied before project entries/overrides. |
| `Projects` | Additional/explicit paths and project settings. |
| `Overrides` | Ordered `Match` rules applied to selected projects. |
| `Release` | Explicitly enabled remote release providers. |

Per-project settings are `Kind` (`Library`, `Desktop`, `Web`, `Console`, `Test`), `Name`, `Pack`, `Publish`, `Archive`, `Runtimes`, `Frameworks`, `TestPlatforms`, `SelfContained`, `SingleFile`, `SelfExtract`, `VersionedArchives`, `ArchiveFormats`, `IncludeSymbols`, `IncludeDevelopmentSettings`, `PackageExcludes`, `PublishArguments` and `Velopack`. `Exclude = $true` in an override skips that project root. `Publish = $false` keeps an application in the build while omitting its publish outputs; `Archive = $false` disables its archives independently. The artifact `Name` must be unique and contain letters, digits, dots, underscores or hyphens.

Desktop, Web/API and Console publish targets default to `SelfContained = $true` and `SingleFile = $true`. Libraries and tests do not use these publishing options. Desktop retains its existing `SelfExtract = $true` compatibility setting; Web/API and Console default to false. These options are independently overridable. Linux archives default to ZIP and tar.gz; Windows archives default to ZIP. Archives include hidden files.

Discovery uses configuration-evaluated properties and common test-package references, including on a clean checkout before package-generated test properties exist. Complex per-framework conditions, unusual SDKs, custom test frameworks or special packaging can require an override. Review the plan; do not rely on discovery to infer every custom MSBuild convention.

### Application deployment options

```powershell
# Enable both, overriding configured application settings
Invoke-AmithBuild -Version 1.2.3 -StandaloneSingleFile

# Override either setting independently, including explicitly disabling it
Invoke-AmithBuild -Version 1.2.3 -SelfContained:$false -SingleFile:$false
```

`-SelfContained` and `-SingleFile` affect application publish targets only, overriding Defaults, project entries and overrides. Omitting them preserves configured settings/defaults. `-StandaloneSingleFile` enables both; it cannot be combined with either individual switch and does not accept `:$false`. Use the individual switches to disable settings. It does not change extraction, trimming or Native AOT settings.

Resolved settings are saved in the plan. Supply deployment options when generating a new plan; later stages reuse those decisions. GitHub Plan inputs are `self-contained` and `single-file` (strings: empty preserves configuration, `'true'`/`'false'` overrides), and `standalone-single-file` (boolean, default false).

For conventional container/Kubernetes deployments, our recommendation is framework-dependent, non-single-file output with an ASP.NET runtime base image. Kubernetes does not require either publishing mode. A self-contained application can instead use `runtime-deps`; ensure the base image matches the runtime and OS requirements. These are deployment choices, not a universal recommendation to bundle every service. Microsoft's [container base-image selection](https://learn.microsoft.com/en-us/dotnet/core/containers/publish-configuration#containerbaseimage) supports both models. For a container-oriented API, use a per-project override:

```powershell
@{ Path = 'src/Api/Api.csproj'; SelfContained = $false; SingleFile = $false }
```

Single-file publishing can still leave native libraries, configuration or symbol files alongside the executable. The shortcut does not enable native-library extraction. IIS in-process hosting requires disabling single-file publishing; see Microsoft's [single-file deployment guidance](https://learn.microsoft.com/en-us/dotnet/core/deploying/single-file/overview).

### Archive filename versions

Archive filenames default to **no version number**, matching the existing production build scripts:

```text
Api-linux-x64.zip
Api-linux-x64.tar.gz
```

`VersionedArchives` is the canonical per-project setting. Enable it to retain the previous Amith.Build convention, for example `Api-linux-x64-1.2.3.zip`:

```powershell
@{
    Defaults = @{ VersionedArchives = $false }
    Overrides = @(
        @{ Match = 'src/Desktop/*'; VersionedArchives = $true }
    )
}
```

CLI options override configuration for all archive targets in a fresh plan:

```powershell
Invoke-AmithBuild -Version 1.2.3 -VersionedArchives
Invoke-AmithBuild -Version 1.2.3 -VersionedArchives:$false
Invoke-AmithBuild -Version 1.2.3 -UnversionedArchives
```

Omitting both switches preserves configured settings, falling back to false. `UnversionedArchives` is an enable-only convenience equivalent to `VersionedArchives:$false`; reject its `:$false` value and use the canonical switch instead. The two switches cannot be combined, even when they agree. Only `VersionedArchives` is stored in the plan and configuration. This affects ZIP/tar filenames; NuGet package and installer naming is unchanged.

Each run remains isolated under `artifacts/<version>/<run-id>/`, preventing collisions between otherwise identical filenames. Within supported schemas, saved plans without this property retain their original versioned naming; create a fresh plan to use the new default.

GitHub Plan inputs are `versioned-archives` (string: empty preserves configuration, `'true'`/`'false'` overrides) and `unversioned-archives` (boolean convenience, default false). Later stages use the saved plan setting.

### Application package contents

All application packages use a prepared copy of the completed publish output, including files added by custom `AfterTargets="Publish"` steps. Other files are retained unless an explicit rule excludes them: `web.config`, `swagger.json`, static-web-assets endpoint manifests, runtime libraries, resources and custom copied content are preserved.

| Per-project setting (also supported in `Defaults`) | Default | Effect |
| --- | --- | --- |
| `IncludeSymbols` | `$true` | Include loose PDBs in ZIP/tar. False excludes them from the prepared folder. Velopack always applies its own PDB exclusion. |
| `IncludeDevelopmentSettings` | `$false` | Exclude `Development.json` and `*.Development.json`, case-insensitively, before publishing/bundling and again when preparing packages. True permits them, including in Velopack; it does not change the application's runtime environment. |
| `PackageExcludes` | `@()` | Additional relative file globs, additive across Defaults, project definitions, matching overrides and CLI. Applies to ZIP/tar and Velopack. |

```powershell
@{
    Defaults = @{ IncludeSymbols = $true; PackageExcludes = @('**/local-cache/**') }
    Overrides = @(
        @{ Match = 'src/Client/*'; PackageExcludes = @('private-notes.txt') }
    )
}

Invoke-AmithBuild -Version 1.2.3 -IncludeSymbols:$false -PackageExcludes '**/scratch/**'
# Explicit exception for a project that requires development configuration:
Invoke-AmithBuild -Version 1.2.3 -IncludeDevelopmentSettings
```

CLI switches override configured booleans; omission preserves them. `PackageExcludes` adds patterns. Globs match the complete relative file path with `/` separators and case-insensitive comparison on every host: `*` matches within a path segment, `?` one character, `**` across directories, and `**/` includes the root directory too. `*.txt` matches root files; `**/*.txt` also matches nested files. There is no negation or include-list syntax. Absolute paths, parent traversal and empty patterns are rejected. Velopack's additional `Excludes` remain regexes with their existing case-sensitive behavior; splash-image rules remain installer-specific.

The injected MSBuild targets remove development JSON from resolved publish items before single-file bundling, including referenced-project content. Existing `CustomAfterMicrosoftCommonTargets` hooks are preserved. Custom targets that deliberately embed content in an assembly or generate their own bundles remain the application's responsibility. `PackageExcludes` filters loose publish output; it cannot remove content already embedded in a binary. Generate a fresh plan and publish again to apply the pre-bundle policy.

Symbols are built normally. This setting does not change compiler debug settings, rewrite embedded symbols or change NuGet `.snupkg` generation. There is no separate private symbol archive. Configuration contents still need project-level review: a filename filter cannot determine whether `appsettings.json` contains a secret.

The plan records `PackageInputs` with included/excluded relative file paths, hashes and reasons; the console shows counts and exclusions. ZIP/tar and Velopack share the same prepared folder, with Velopack's additional exclusions. Changed source/prepared files stop reuse rather than mixing inputs. Symbolic links and junctions in publish output are rejected instead of following them outside the output tree; publish actual file content for packaging. Prepared output preserves Unix executable permissions.

GitHub Plan inputs are `include-symbols` and `include-development-settings` (strings: empty preserves configuration; `'true'`/`'false'` overrides), and `package-excludes` (newline-separated globs). They are accepted only at Plan.

## Stages and build plans

```text
Plan -> Restore -> Build -> Test
                         -> Pack       (NuGet)
                         -> Publish -> Archive
                                    -> Installer (optional Velopack)
             explicit Retain -> recorded packages for CI artifact retention
             explicit Release -> NuGet push and/or draft-first GitHub release
```

A normal local invocation runs Restore, Build, Test, Pack, Publish, Archive and Installer. Inapplicable stages are no-ops. **Release is never part of the default invocation.** Omitting Version uses `0.0.0-local`; remote Release requires an explicit version.

The current plan schema identifier is a string:

```json
"SchemaVersion": "1alpha1"
```

Schema identifiers follow a Kubernetes-inspired convention without the leading `v`: `1alpha1`, `1beta1`, `1`, and eventually `2alpha1`, independently of module/action SemVer releases. The reader explicitly accepts the current identifier, including its exact case; it does not infer compatibility from ordering. Earlier numeric identifiers are unsupported and require regenerating the plan.

**Unreleased development policy:** keep `1alpha1` unchanged, including through incompatible schema changes, until the first alpha version is released. Only changes after that release are candidates for a schema increment. During this development period, a matching identifier is not a guarantee that an older plan is compatible: regenerate plans after changing the tooling. Stable identifiers such as `"1"` will remain strings too.

Preview selection without building, testing or contacting release services:

```powershell
Invoke-AmithBuild -Version 1.2.3 -PlanOnly
```

Inspect `.amith-build/plan.json`, then execute separate stages:

```powershell
Invoke-AmithBuild -PlanPath .amith-build/plan.json -Stages Restore,Build,Test
Invoke-AmithBuild -PlanPath .amith-build/plan.json -Stages Pack,Publish,Archive,Installer
Invoke-AmithBuild -PlanPath .amith-build/plan.json -Stages Release
```

Plan creation evaluates projects using dotnet/MSBuild and may resolve SDKs. It does not run build targets or restore ordinary project packages. Plans are snapshots: regenerate after changing selection/configuration. Keep all stages on the same checkout/host and run them sequentially; cross-job plan relocation and parallel mutation of one plan are not supported.

Each plan uses `artifacts/<version>/<unique run ID>/`. The manifest records exact package/archive files and SHA-256 hashes. Failed stages stop execution; packaging/release gates reject failed producer stages and changed artifacts. Rebuilds invalidate prior packaging gates. No global source-tree cleanup or package deletion is performed. Old output retention is an explicit operator/workspace policy.

The optional `Retain` stage prepares `RetainedRoot` containing only recorded Archive, Installer, NuGet and Symbols artifacts whose producer succeeded and whose hashes still match. The shared workflow uploads only that directory. Raw publish output, plans, downloaded delta bases and unrecorded files from failed attempts are not uploaded. `Retain` does not rebuild or publish anything and is not a default local stage. The composite exposes `retained-root` after Retain.

Add `.amith-build/`, `artifacts/` and, if used, `.amith-tools/` to the consuming repository's `.gitignore`.

## Test policy

The default Test stage requires at least one selected, host-compatible test target to complete successfully. No test projects, or no targets runnable on the current host, fails with guidance instead of silently allowing release.

| CLI switch / top-level configuration | Behaviour |
| --- | --- |
| Neither | Run eligible tests; fail when none can run. |
| `-NoTests` / `NoTests = $true` | Declare that the selected plan intentionally has no test projects. Planning fails if any selected project is classified as Test, including host-incompatible tests. |
| `-SkipTests` / `SkipTests = $true` | Explicitly bypass execution, whether or not test projects exist. Selected test projects remain normal restore/build roots when host-compatible. |

The two choices are mutually exclusive. CLI switches override configuration, including explicit `:$false`. Supply them when creating the plan; subsequent stages reuse its saved `TestPolicy`. A test-free plan can still be inspected with `-PlanOnly` without declaring a bypass, but its Test stage fails until the policy is explicitly chosen in a fresh plan.

```powershell
# Intentional test-free solution.
Invoke-AmithBuild -Version 1.2.3 -NoTests

# Explicitly bypass execution for this build.
Invoke-AmithBuild -Version 1.2.3 -SkipTests

# Re-enable normal testing when configuration specifies SkipTests.
Invoke-AmithBuild -Version 1.2.3 -SkipTests:$false
```

GitHub Plan inputs are `no-tests` and `skip-tests`: optional strings, empty to preserve configuration and `'true'`/`'false'` to override it. The reusable workflow exposes both:

```yaml
with:
  version: 1.2.3
  no-tests: 'true'
```

The Test stage must still run for an intentional bypass. It records `TestResults.Disposition` as `NoTests` or `Skipped`, records skipped project names where applicable, and prints a warning. Normal completion records `Executed` and the number of successfully invoked targets. Release requires a successful Test stage plus either an executed target or a matching recorded intentional bypass; changing a flag alone does not satisfy that gate. Releases with a bypass print that decision explicitly. Rebuilds invalidate previous results, and rerunning Test invalidates the previous release gate.

Requiring a runnable target is now the default. The earlier `Release.RequireTestExecution` opt-in is no longer necessary; setting it false does not relax this policy. Explicit `NoTests`/`SkipTests` choices govern intentional bypasses, including when that older setting is true. Saved plans without a test policy default to required testing; regenerate plans after updating unreleased tooling.

This checks successful test-target invocation, not individual test-case counts. A runner reporting success with zero cases remains acceptable. If only Windows tests exist on a Linux runner, use a compatible runner or explicitly skip execution; `NoTests` is not a substitute for a platform mismatch.

## Linux hosts and Windows outputs

A `runners` group can run the tooling on Linux with PowerShell 7.4+ and the required SDKs installed. WPF builds use `EnableWindowsTargeting`; this does not enable running Windows applications/COM on Linux. COM-reference resolution, native compilers and other platform-specific MSBuild tasks may still require a Windows build host. The tool does not switch the library target framework merely because the build host is Linux.

Tests run only for host-compatible target frameworks and `TestPlatforms`. Windows-only test targets are reported as skipped on Linux. `TestResults` records executed targets and skipped projects. The Test stage fails if no target can run unless an explicit test-policy bypass is recorded. For tests with a portable TFM but Windows-specific assumptions, supply `TestPlatforms = @('Windows')` or fix/split those tests. A successful cross-build is not a platform-specific runtime test.

MTP and VSTest invocation are selected from the repository's `global.json` test runner setting. Test projects need their normal test SDK/adapter dependencies. The scripts do not install them or alter their target frameworks.

## NuGet restore feeds

The reusable workflow configures dependency feeds before Plan/Restore. Consumers supply JSON through the optional `NUGET_RESTORE_SOURCES` workflow secret; no consumer-maintained NuGet configuration file is required. Existing separate repository secrets can be used directly:

```yaml
jobs:
  build:
    uses: Amith211/Amith.Build/.github/workflows/build.yml@v0.1.1
    with:
      version: ${{ inputs.version }}
    secrets:
      NUGET_RESTORE_SOURCES: |
        [
          {
            "name": "Amith",
            "url": "https://packages.example.invalid/v3/index.json",
            "username": ${{ toJSON(secrets.NUGET_FEED_USERNAME) }},
            "password": ${{ toJSON(secrets.NUGET_FEED_PASSWORD) }}
          },
          {
            "name": "PublicExample",
            "url": "https://public.example.invalid/v3/index.json"
          }
        ]
```

Use `toJSON` without extra surrounding quotes so special characters are escaped correctly. This constructs the payload from existing secrets; a combined repository secret is not necessary. URLs may also come from repository variables or secrets. The entire payload is passed through `secrets:`, because reusable-workflow `with:` inputs cannot reference repository secrets.

| JSON field | Behaviour |
| --- | --- |
| `name` | Required unique source name. Names containing spaces are supported; duplicates differing only by case are rejected. |
| `url` | Required absolute HTTP(S) URL or filesystem path. Embedded URL credentials are rejected. NuGet's normal HTTP/TLS policy still applies. |
| `username`, `password` | Optional together. Supplied values must be nonempty strings; missing GitHub secrets fail validation. PATs use the password field and the username required by that feed. |
| `validAuthenticationTypes` | Optional comma-separated restriction, such as `basic`. Requires explicit credentials. Omission preserves an existing restriction, or NuGet's normal negotiation when none exists. |

Omitting both credential fields leaves NuGet's existing authentication discovery in place, including installed credential providers; it does not force anonymous access. This initial feature does not install providers or provision client certificates.

The setup action adds/updates named sources in the .NET CLI's user-level configuration: `%APPDATA%/NuGet/NuGet.Config` on Windows and `~/.nuget/NuGet/NuGet.Config` on Linux/macOS. It preserves unrelated sources, source mapping, disabled sources, certificate settings and credentials. A newly created user configuration also includes nuget.org. Omitted/empty source lists make no configuration changes.

Explicit credentials are exported as uniquely named process/job environment variables. Configuration stores only their `%VARIABLE_NAME%` references, never the supplied password or username. Existing encrypted passwords for an explicitly configured credential entry are replaced with the macro reference. No literal password is passed to a native command. Values are masked in GitHub logs and are not recorded in build plans or retained packages. The GitHub environment command file necessarily carries the values to later steps; keep runner job state ephemeral and rerun setup for each job.

Repository NuGet policy is respected: a repository's `<clear />`, source override or disabled-source setting may shadow the user-level source. Setup reports a warning when a supplied URL is not enabled at the workspace root; it does not rewrite repository configuration. Nested project configurations can impose additional policy. Existing `NuGetPackageSourceCredentials_<name>` variables take precedence over configuration macros; setup warns and preserves them.

For a consumer-owned workflow using individual composite stages, call the setup action after PowerShell/.NET setup and before Plan:

```yaml
- name: Configure NuGet restore feeds
  uses: Amith211/Amith.Build/setup-nuget@v0.1.1
  env:
    AMITH_NUGET_RESTORE_SOURCES: ${{ secrets.NUGET_RESTORE_SOURCES }}
```

For local use, populate the same environment variable and run `scripts/Initialize-AmithNuGet.ps1` from the consumer root in the PowerShell session that will build. An optional `-ConfigPath` targets an explicitly chosen NuGet file, mainly for isolated testing; normal CI needs no file-path input. Restore authentication is separate from the publishing URL/API-key secrets described below.

## NuGet releases

```powershell
Release = @{
    NuGet = @{
        Enabled = $true
        SourceEnvironment = 'NUGET_SOURCE_URL'
        ApiKeyEnvironment = 'NUGET_API_KEY'
    }
}
```

The feed URL and API key come only from the named environment variables, mapped from GitHub secrets in CI. No private feed URL or credential is embedded in the scripts. Native command output is redacted for supplied secrets and feed authority. Missing credentials stop Release.

Successful pushes are recorded in the plan, so retrying the same partially completed plan skips its already-confirmed identical packages. A new plan does not silently skip conflicting feed versions. Packages are retained on failure. Symbol packages are retained as artifacts; this initial adapter does not automatically push symbols to a separate symbol server.

## Application and GitHub releases

```powershell
Release = @{
    GitHub = @{
        Enabled = $true
        Repository = 'Amith211/MyApp'
        TagPrefix = 'v'
        RequireCleanTree = $true
        Draft = $false
    }
}
```

Requires `gh`, authenticated through `GH_TOKEN` or local GitHub CLI authentication. The source commit must match the commit recorded in the build plan; regenerate after changing commits. The source must be committed; the default clean-tree check ignores the generated plan/output directories. The adapter creates a draft, uploads the exact manifest artifacts, then publishes the draft. Failed uploads leave it as a draft. An existing published version is rejected; an existing draft can be resumed. Multiple providers in one Release are sequential and do not provide transactional rollback across hosting services.

### Velopack adapter

Enable per project:

```powershell
Velopack = @{
    Enabled = $true
    PackId = 'MyDesktopApp'
    MainExe = 'Client.exe'
    Authors = 'Amith'
    Channel = 'win'
    PackArguments = @('--icon', 'build/app.ico')
    DownloadPrevious = $true # Default; no previous release/channel is OK.
    Excludes = @('(^|[\\/])local-cache[\\/]') # Additional regexes, additive to mandatory defaults.
    Repository = 'Amith211/MyDesktopApp'
}
```

Installer first uses `Velopack.ToolVersion`, or infers the version from the restored Velopack dependency in `project.assets.json` (including transitive dependencies). It installs that version into a persistent cache separated by version, OS and architecture without changing global tools. If no version can be inferred, an already-installed `vpk` is used; otherwise the stage explains how to configure one. Installer calls the explicit `[win]`/`[linux]` directive with the planned RID; it never assumes the runner OS is the package OS. Linux AppImage packaging and code signing may require additional external tools/arguments. Resolve asset paths in extra arguments relative to the consumer root.

For delta generation, `DownloadPrevious` defaults to true and uses `vpk download github` before packaging. A successful empty download (no previous release, channel feed or applicable full package) continues as a first release. Public repositories can download anonymously; set `GH_TOKEN` (or `TokenEnvironment`) for private repositories. Authentication, network and malformed-package failures stop the stage. Incomplete downloads are rejected even if the tool exits successfully after a checksum error. Downloaded packages are validated against the configured application ID and copied into a fresh packaging directory as delta bases; only files listed by the new `assets.<channel>.json` build manifest are recorded as generated package artifacts. Both failed attempts and previous bases are retained locally, with each attempt isolated in its own directory.

Default Velopack exclusions include `.*\.pdb`, development JSON and splash images, using both path separators. Matching is case-sensitive. `Velopack.Excludes` adds regex patterns; legacy `PackArguments = @('--exclude','...')` is also additive. One combined regex is passed to `vpk pack`. `PackArguments` cannot override the planned ID/version, directories, runtime, channel or entry executable, or disable built-in exclusions. PDB and splash-image exclusions cannot be disabled through this adapter. `IncludeDevelopmentSettings = $true` removes only the built-in development-JSON rule; explicitly supplied regexes still apply.

GitHub releases are created as drafts. Archives (and any ordinary NuGet/symbol packages) are uploaded with `gh`; Velopack packages and channel feeds are uploaded exclusively using `vpk [<os>] upload github --merge`, never `--publish`. Velopack uses its build-assets manifest, rather than uploading every older package in its output directory. The orchestrator publishes with `gh` only after all uploads and remote-asset checks succeed; `Release.GitHub.Draft = $true` keeps the finished release as a draft. Upload failures retain the draft.

Every target in a shared release needs a distinct channel/feed filename and unique uploaded asset filenames. `Channel` remains the single-channel option, defaulting to `win` or `linux` from the target OS. For multiple architectures, use `Channels = @{ 'win-x64' = 'client-win-x64'; 'win-arm64' = 'client-win-arm64' }`; runtime mappings override `Channel`. Use different channels for different applications too. Cross-repository download/upload configurations are rejected.

Completed Velopack channel uploads are recorded in the plan and verified against the draft before retrying or publishing. A retry skips verified completed channels and can retry a channel that uploaded no assets. Velopack `--merge` cannot replace an existing same-channel feed or overwrite partial asset uploads: those cases fail with a clear message, keeping the release in draft. Remove only that channel's partial/conflicting assets from the draft before retrying the same plan. The scripts never delete remote assets automatically. Missing/changed completed remote assets or changed local artifacts also stop publication. Older plans whose Installer stage predates the upload manifest must rerun Installer before GitHub release.

## GitHub Actions: separate steps

`action.yml` exposes the same engine. Every stage is a visible caller workflow step:

```yaml
- name: Plan
  uses: Amith211/Amith.Build@v0.1.1
  with:
    stage: Plan
    config: amith.build.psd1
    version: ${{ inputs.version }}
    runtimes: win-x64,linux-x64
- name: Restore
  uses: Amith211/Amith.Build@v0.1.1
  with:
    stage: Restore
- name: Build
  uses: Amith211/Amith.Build@v0.1.1
  with:
    stage: Build
- name: Test
  uses: Amith211/Amith.Build@v0.1.1
  with:
    stage: Test
- name: Package
  uses: Amith211/Amith.Build@v0.1.1
  with:
    stage: Pack,Publish,Archive,Installer
```

The caller checks out its source and sets up SDKs first. The action runs on the caller's runner and uses the exact downloaded action directory; it does not search for a copied module in the consumer repo. Inputs are passed through environment variables/typed arguments, not interpolated into shell command text. Package selection inputs are `pack-projects`, `pack-only-projects`, `exclude-pack-projects` (comma-separated names), `pack-all-libraries` and `no-pack`. Supply these to Plan only; subsequent stages use the saved selection. The reusable workflow exposes the same inputs.

`examples/github/caller.yml` demonstrates the complete reusable workflow, with:

```yaml
uses: Amith211/Amith.Build/.github/workflows/build.yml@v0.1.1
with:
  version: ${{ inputs.version }}
  runner-group: Amith-runners
  config: amith.build.psd1
  release: true
```

The reusable workflow calls the matching `@v0.1.1` actions for each stage. Published version tags remain fixed. Patch releases use new tags such as `v0.1.2`; consumers select the version they want to test or adopt. Incompatible changes can occur while the tooling is prerelease and should be documented in release notes.

The reusable full-release workflow requests `contents: write` for GitHub release support. A NuGet-only consumer can use the composite action with `contents: read`. Supply `NUGET_SOURCE_URL`/`NUGET_API_KEY` for feed publishing and `RELEASE_TOKEN` when a custom GitHub token is needed. The built-in caller token is the default GitHub token. `vpk` is needed only when Installer is enabled for a project; project-specific Velopack tools are isolated rather than globally updated. The reusable workflow bootstraps PowerShell and GitHub CLI through the shared setup-tools action; `powershell-tag` can pin its release.

### Release concurrency

The shared workflow runs one release job at a time per calling repository, across versions, refs and caller workflows. It holds the queue for the whole build/package/release job so Velopack previous-release downloads and publication cannot overlap another shared release from that repository. New release runs wait; they do not cancel the running release or replace an already queued release.

The workflow uses GitHub concurrency with queue: max and cancel-in-progress: false. GitHub allows up to 100 pending jobs per group; extra jobs are cancelled if that queue is full. Queue order follows when jobs start waiting, so dispatch order is not guaranteed. Build-only runs have a separate group per run/attempt and do not contend with release runs or other build-only runs.

Concurrency is scoped to the calling repository. Separate repositories targeting the same external feed/release repository, local commands and custom workflows using individual stages need their own coordination. If the caller also defines concurrency, use a different group from the shared job's amith-build-release-<owner/repository> group to avoid waiting on its own lock. See [GitHub's concurrency documentation](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).

### Diagnostic runner hold

The shared workflow supports an optional post-job hold for inspecting a self-hosted runner or Kubernetes runner pod. It is disabled by default. Enable it in the caller:

~~~yaml
with:
  keep-runner-alive: true
  keep-runner-alive-minutes: 60
  runner-timeout-margin-minutes: 30
~~~

keep-runner-alive-minutes accepts whole minutes from 1 to 360, or -1 for the maximum remaining budget. The common job limit is six hours (360 minutes) on self-hosted and GitHub-hosted runners. runner-timeout-margin-minutes reserves 30 minutes by default and accepts whole minutes from 1 to 359. The actual wait is capped at job registration time plus 360 minutes minus the margin, counting work already completed. For example, with a 30-minute margin and 40 minutes of work, -1 allows at most another 290 minutes. A normal 60-minute request waits only 60 minutes if that much budget remains. An exhausted budget skips the hold.

Registration is the first shared-workflow step, before checkout or PowerShell/.NET setup. Its Node post-hook runs at the end, after normal steps and other registered post-action cleanup, even when a build step fails. Failed steps still stop the remaining ordinary steps; the hold does not turn a failed job into a successful one. Registration validates all duration inputs before work starts.

The hook records wall time and OS uptime and caps its timer against both the remaining whole-job budget and monotonic elapsed time. Invalid clock state is handled conservatively. Cancel the workflow to stop an active hold; already-cancelled jobs skip it. The job remains active during a hold and continues to occupy its release-concurrency slot.

This keeps the job allocated; it does not start SSH services or an interactive shell. Use your existing runner/pod administration tools to connect. Registration must have started successfully: runner loss, forced termination and hard job timeouts cannot be recovered by this hook.

Consumer-owned workflows can register the same action before their other steps. Use a 360-minute job timeout to match the shared budget; a shorter job/step timeout can terminate the hold earlier:

~~~yaml
- uses: Amith211/Amith.Build/runner-diagnostics@v0.1.1
  with:
    keep-runner-alive: true
    keep-runner-alive-minutes: -1
    runner-timeout-margin-minutes: 30
~~~

### Public tooling, private consumers

The public `Amith211/Amith.Build` can be consumed by personal and organisation repositories, subject to their Actions policies. Consumer configuration, source and secrets remain in the calling repository; using public tooling does not publish them. The reusable workflow defaults to the existing self-hosted runner group; examples use `Amith-runners`. Amith.Build's own validation uses GitHub-hosted runners.

## Maintaining the shared release line

Publish signed, fixed version tags after validation. Do not move a previously published tag to deliver a patch; publish a new version and update the caller reference. Mark early releases as prereleases in GitHub.

Examples require the referenced version tag to exist. This implementation does not automatically create a remote repository or move tags.

## Validation

```powershell
./tests/Test-AmithBuild.ps1
./tests/Test-AmithBuild.ps1 -Integration
```

The checks need no Pester dependency. Native failures, discovery/overrides, project kinds, runtime filtering, stage gates, artifact integrity, package retention and draft-first GitHub ordering are tested with fake publishing commands. Integration creates isolated temporary library, console, web API and minimal WPF projects and really builds, packs and publishes Windows/Linux outputs; it never pushes packages or creates releases. The same test command is wired to a GitHub-hosted Windows/Linux matrix in `validate.yml`.

No existing consumer workflow is automatically migrated. Validate each project's plan/configuration and its platform-specific packaging before adopting the central release pipeline.

Library builds and NuGet packing explicitly use a portable target rather than inheriting application publish RIDs. Tests are restored, built and run for the current host runtime, independently of the Windows/Linux publish runtime list. Restore uses the selected configuration and version too. Build allows incremental restore checks because another project or framework can replace a shared dependency's assets file with a different set of targets between stages. Test and Pack also refresh matching assets before using their existing binaries, including when earlier stages restored a different framework. This avoids stale-assets failures without deleting source outputs.

## Shared tool setup and cache

The reusable workflow prepares PowerShell and GitHub CLI before running any PowerShell steps. It uses the runner's Node runtime to bootstrap PowerShell, so PowerShell 7 need not already be installed. Empty powershell-tag and gh-version inputs select each tool's latest stable release; exact versions can be supplied to pin them. Downloads come from the official projects and are checked against their SHA256 release metadata/checksums.

The tool-cache-path input overrides the cache location. The shared workflow defaults to /opt/hostedtoolcache on Linux. When used independently, the setup action uses AMITH_TOOL_CACHE, then RUNNER_TOOL_CACHE, with /opt/hostedtoolcache as the Linux fallback. Mount your persistent Kubernetes volume at that path, or point tool-cache-path at its mount. The setup action exports AMITH_TOOL_CACHE for later stages. Local PowerShell builds use that variable or RUNNER_TOOL_CACHE when set, otherwise the user's ~/.cache/amith-build/tools directory.

Installations are separated by tool, version, OS and architecture. Cache hits still restore PATH and validate the executable. Locks prevent concurrent writers from installing over each other; incomplete installations have no ready marker and are replaced on the next attempt. An interrupted Node installation may leave a lock directory; after confirming no installer is running, remove that specific lock and retry. Cached tools are not uploaded with release artifacts. Keep the cache on a trusted runner volume.

Velopack keeps the existing selection order: explicit ToolVersion, restored Velopack dependency version, then an installed vpk if no version can be inferred. Selected versions use the persistent cache instead of the build output directory. SDK availability and build selection are controlled by the SDK setup below; add an older SDK when a tool requires its runtime.

Linux shared builds also check/install zstd using apt-get (with sudo for non-root runners). This requires an Ubuntu/Debian-compatible runner and installation privileges when zstd is missing. For v0.1, legacy PATH discovery is retained across the existing tool roots, tolerating missing directories and paths containing spaces. Selected PowerShell/GitHub CLI installations take precedence. Discovery matches find -maxdepth 5, deduplicates against the inherited PATH, and omits optional directories when the combined PATH would exceed its safety budget. Omitted directories are reported with a warning.

Consumer-owned workflows can use the same setup without the reusable workflow:

~~~yaml
- uses: Amith211/Amith.Build/setup-tools@v0.1.1
  with:
    tool-cache-path: /opt/hostedtoolcache
    # powershell-tag: v7.7.0
    # gh-version: v2.104.0
~~~

The action supports Windows/Linux x64 and arm64; validation runs x64 on both operating systems. Existing .NET setup and NuGet credential configuration remain separate.

## SDK selection and availability

Local builds and shared workflow stages select an SDK through the native .NET host using a cached SDK profile. SdkVersion defaults to auto. CLI selection overrides repository configuration; AdditionalSdks adds to configured SDK availability.

~~~powershell
Invoke-AmithBuild -Version 1.2.3 -SdkVersion 10 -AdditionalSdks 8.0.x
~~~

~~~powershell
@{
    SdkVersion = 'auto'
    AdditionalSdks = @('8.0.x')
}
~~~

Selectors are auto, latest (latest supported stable SDK), a major such as 10, a channel such as 10.0 or 10.0.x, or an exact version such as 10.0.100. Exact prerelease SDKs must be requested explicitly. AdditionalSdks accepts the same selectors except auto and never changes the selected build SDK.

Auto honours an existing global.json SDK policy first. Without one, it uses the latest supported stable SDK to evaluate the selected projects with MSBuild, selects the highest evaluated modern target's SDK channel, then evaluates project defaults again under the selected SDK. Evaluated .NET Standard/.NET Framework-only targets use the latest supported stable LTS SDK. Evaluation failures and unknown targets require an explicit selection; SDK-dependent target declarations that do not converge also fail clearly. Framework targets are not changed.

Every supported stable channel in active/maintenance support is available in the cache, together with explicitly requested additional versions and any global.json baseline. Installed SDKs are reused where possible. Missing SDK archives come from Microsoft's release metadata and are verified against its SHA512 checksums. Windows/Linux x64 and arm64 are supported; Alpine uses the linux-musl SDK archive.

Profiles use an ordinary portable .NET directory layout, containing the requested SDKs and the available runtimes/reference packs. They do not edit global.json or use symlinks to override it. The native host decides whether a request satisfies the existing policy. Compatible policies work normally; incompatible requests fail with the requested/selected SDK information. Nested project policies must agree with the selected build SDK. No IgnoreGlobalJson switch is provided.

The saved plan records the chosen SDK profile and global.json snapshots. Later stages validate them before executing; policy changes or missing profiles require a fresh plan. Local commands restore PATH and .NET environment variables on success and failure. Workflow scripts export the selected host for subsequent steps. Profiles and SDK downloads remain in the trusted tool cache, outside retained release artifacts. First use needs download space plus profile copies; subsequent matching builds reuse them.

The shared workflow exposes sdk-version and comma/newline-separated additional-sdks. An empty sdk-version preserves configuration and the auto default. The older dotnet-version input remains a single-selector alias; supplying both names fails. Multi-version installation belongs in additional-sdks. Bootstrap runs before NuGet feed setup, then Plan applies repository configuration and target inference.

For consumer-owned workflows, use setup-tools first (PowerShell bootstrap), then setup-dotnet before configuring restore feeds and calling Plan:

~~~yaml
- uses: Amith211/Amith.Build/setup-dotnet@v0.1.1
  with:
    sdk-version: auto
    additional-sdks: |
      8.0.x
~~~

The standalone Resolve-AmithSdkRequirements command and scripts/Resolve-AmithSdk.ps1 still provide metadata-only preflight:

~~~powershell
Resolve-AmithSdkRequirements -RootPath ./ -SdkVersion 10 -AdditionalSdks 8.0.x
./scripts/Resolve-AmithSdk.ps1 -RootPath ./ -TargetFrameworks netstandard2.0,net10.0
~~~

That preflight alone does not install or select an SDK. It returns RequestedSdkVersion, SelectionSource, BootstrapSdkVersion, SupportedSdkVersions, AdditionalSdkVersions, InstallSdkVersions and the discovered GlobalJson policy. RequiresGlobalJsonValidation marks results still requiring native host validation. Saved preflight/build plans contain machine paths and should stay with private/local build metadata.

SDK setup does not install OS prerequisites, native compilers, workloads or credential providers. Add an older SDK when a test/tool requires its runtime; unsupported runtime dependencies still fail through the native tool. Previously saved plans without SDK execution metadata retain their earlier host-resolution behaviour; create a fresh plan to adopt SDK selection. Microsoft's [release metadata](https://github.com/dotnet/core/tree/main/release-notes) supplies versions, and the [.NET host's global.json rules](https://learn.microsoft.com/en-us/dotnet/core/tools/global-json) remain authoritative.


### Planning diagnostics

Planning and SDK setup print timestamped start/completion messages with elapsed seconds. These identify metadata requests, installed-SDK searches, SDK downloads/checksums/extraction, profile preparation, support/compiler directory copies, solution discovery and individual project evaluation. Cache hits remain visible, and contended SDK cache locks report waiting progress every 30 seconds.

These messages are enabled by default and use the PowerShell information stream, preserving operation return values and failures. They log operation labels, SDK versions and filesystem paths rather than environment dumps, credentials or command arguments. A start message without its corresponding completion identifies the operation still running; the enclosing completion includes time spent in nested work. Additional installed SDKs can add profile-copy work even when no SDK download is needed.
