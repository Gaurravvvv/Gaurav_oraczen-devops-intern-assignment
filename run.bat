@echo off
cd /d "%~dp0"

echo ===================================
echo   Starting Notes API
echo ===================================

:: Activate virtual environment if available
if exist venv\Scripts\activate.bat (
    call venv\Scripts\activate.bat
) else if exist .venv\Scripts\activate.bat (
    call .venv\Scripts\activate.bat
)

:: Set default environment variables
set POSTGRES_HOST=localhost
set POSTGRES_PORT=5432
set POSTGRES_USER=notes
set POSTGRES_PASSWORD=notes
set POSTGRES_DB=notes

:: Check if postgres container is running
docker ps --filter "name=notes-postgres" --format "{{.Names}}" 2>nul | findstr /i "notes-postgres" >nul
if errorlevel 1 (
    echo Starting PostgreSQL container...
    docker start notes-postgres >nul 2>&1
    if errorlevel 1 (
        docker run -d --name notes-postgres -p 5432:5432 -e POSTGRES_USER=notes -e POSTGRES_PASSWORD=notes -e POSTGRES_DB=notes postgres:16 >nul 2>&1
    )
)

echo.
echo Application URL: http://localhost:8000
echo Health check:    http://localhost:8000/healthz
echo Readiness check: http://localhost:8000/readyz
echo.
echo Press Ctrl+C to stop the server.
echo ===================================
echo.

cd app
python -m uvicorn main:app --reload --host 0.0.0.0 --port 8000

echo.
pause
