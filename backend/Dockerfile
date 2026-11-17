# Build context is this `backend/` directory, not the repository root:
#
#   docker build -t cafeops-api backend
#
# Render and Fly.io both let you set that as the root directory.

# ----------------------------------------------------------------- build ----

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# Project files first, on their own layer. Restore only re-runs when a
# dependency actually changes, rather than on every source edit, which is the
# difference between a 10-second rebuild and a 2-minute one.
COPY CafeOps.slnx ./
COPY src/CafeOps.Domain/CafeOps.Domain.csproj                 src/CafeOps.Domain/
COPY src/CafeOps.Infrastructure/CafeOps.Infrastructure.csproj src/CafeOps.Infrastructure/
COPY src/CafeOps.Api/CafeOps.Api.csproj                       src/CafeOps.Api/

RUN dotnet restore src/CafeOps.Api/CafeOps.Api.csproj

COPY src/ src/

RUN dotnet publish src/CafeOps.Api/CafeOps.Api.csproj \
        --configuration Release \
        --no-restore \
        --output /app

# --------------------------------------------------------------- runtime ----

# The aspnet image, not the SDK: it is a fraction of the size and carries no
# compiler, so a container that is somehow compromised has far less to work
# with.
FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app

COPY --from=build /app ./

# Default for platforms that do not set PORT. Where one does — Render, Fly,
# Cloud Run — Program.cs binds that instead.
ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080

# Non-root. The image ships this user; using it costs nothing and means a
# process escape does not start as root.
USER app

ENTRYPOINT ["dotnet", "CafeOps.Api.dll"]
