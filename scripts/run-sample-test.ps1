$ErrorActionPreference = 'Stop'

docker compose up --detach --wait
if ($LASTEXITCODE -ne 0) {
    throw 'Docker Compose did not start a healthy MySQL service.'
}

docker compose exec --no-TTY mysql `
    sh /workspace/scripts/run-sample-test.sh
if ($LASTEXITCODE -ne 0) {
    throw 'The sample database test failed.'
}
