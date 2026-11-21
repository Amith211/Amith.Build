# Container example

Run commands from this directory after changing `Image` to your Harbor repository.
The example deliberately declares `NoTests`; production consumers should select
and execute their normal tests.

```powershell
Import-Module ../../src/Amith.Build/Amith.Build.psd1
# Register a builder once; this does not start or remove the remote daemon.
docker buildx create --name cluster --driver remote tcp://buildkitd.arc-buildkit.svc:1234
Invoke-AmithBuild -Version 1.2.3 -ContainerBuilder cluster
# Authenticate to Harbor separately. Release needs Skopeo on PATH.
Invoke-AmithBuild -PlanPath .amith-build/plan.json -Stages Release
```

Use the reusable workflow inputs `container-builder-endpoint` and optionally
`container-buildx-version`; provide `CONTAINER_REGISTRY_USERNAME` and
`CONTAINER_REGISTRY_PASSWORD` for private pulls/publication. The workflow runs on
Linux and installs Skopeo from apt when publishing. Local callers manage their
Buildx installation/builder and Skopeo themselves.

The runtime image is framework-dependent and runs as the .NET image's non-root
user on port 8080. The Dockerfile cross-compiles .NET for the requested target
architecture; workloads with native dependencies may require a different recipe.
An OCI archive proves packaging succeeded; this example does not execute a
container or deploy it.

For private package feeds, enable the commented `nuget_config` secret mapping.
The generated configuration uses exactly the supplied HTTP(S) sources. Include
nuget.org in `NUGET_RESTORE_SOURCES` too if required. Host credential providers,
filesystem feeds and repository source-mapping policy are not transferred.

Set `Release.Containers.TagAsLatest = $true` to publish the same digest as both
the version tag and `latest`. Permit moving `latest` in Harbor's immutability
rules. This opt-in also moves `latest` for prereleases and older release versions;
it does not trigger a Kubernetes rollout.

For reusable workflows, consume `Amith211/Amith.Build/.github/workflows/build.yml@v0.2.0-alpha.3`
after that version has been validated and tagged. This change does not create a tag.

For container-only execution, use `-BuildMode containers` locally or
`build-mode: containers` in a supporting reusable-workflow release. This example
explicitly declares `NoTests`, so runner Restore/Build/Test record that bypass
without compiling the API outside Docker. Real applications should define root
`TestSuites` and reference them from each container to run relevant runner tests.
Full mode continues to build its configured API root. Container-only mode never
publishes GitHub release assets or NuGet packages. This mode requires `v0.2.0-alpha.3` or later.
