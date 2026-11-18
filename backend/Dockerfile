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

# Kerberos runtime library.
#
# The aspnet images are Debian slim and do not ship libgssapi_krb5.so.2. When Npgsql opens a
# connection it looks at the authentication methods the server offers, and touching the
# GSSAPI path makes .NET try to load that library. Postgres then falls back to SCRAM and the
# connection succeeds, so the app works — but every connection logs
#
#   libgssapi_krb5.so.2: cannot open shared object file: No such file or directory
#
# which is alarming in production logs and buries anything that actually matters. Installing
# it costs about a megabyte and makes the probe succeed quietly. This has to happen before
# USER app, because apt needs root.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libgssapi-krb5-2 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /app ./

# Default for platforms that do not set PORT. Where one does — Render, Fly,
# Cloud Run — Program.cs binds that instead.
ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080

# Non-root. The image ships this user; using it costs nothing and means a
# process escape does not start as root.
USER app

ENTRYPOINT ["dotnet", "CafeOps.Api.dll"]
