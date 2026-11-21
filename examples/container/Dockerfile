# syntax=docker/dockerfile:1
FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY Api/ Api/
ARG TARGETARCH
ARG CONFIGURATION=Release
ARG AMITH_VERSION
ARG AMITH_SOURCE_COMMIT
# Restore and publish share one RUN so an evicted package cache is repopulated
# even when earlier source-copy layers were reused. Optional credentials are
# mounted for this instruction only and never copied into the image.
RUN --mount=type=cache,id=bcs-nuget,target=/root/.nuget/packages,sharing=locked \
    --mount=type=secret,id=nuget_config \
    if [ -f /run/secrets/nuget_config ]; then \
      dotnet restore Api/Api.csproj -a "$TARGETARCH" --configfile /run/secrets/nuget_config; \
    else \
      dotnet restore Api/Api.csproj -a "$TARGETARCH"; \
    fi && \
    dotnet publish Api/Api.csproj --no-restore -a "$TARGETARCH" -c "$CONFIGURATION" \
      --self-contained false -p:UseAppHost=false -p:Version="$AMITH_VERSION" \
      -p:SourceRevisionId="$AMITH_SOURCE_COMMIT" -o /app
FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
COPY --from=build /app/ ./
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["dotnet", "Api.dll"]
