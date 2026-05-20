# MLflow server with OIDC authentication.
# Uses the mlflow-oidc-auth plugin to integrate with Authentik SSO.
#
# Required environment variables (set in .secrets/mlflow.env):
#   POSTGRES_PASSWORD, OIDC_DISCOVERY_URL, OIDC_CLIENT_ID, OIDC_CLIENT_SECRET,
#   SECRET_KEY, OIDC_REDIRECT_URI, OIDC_GROUP_NAME, OIDC_ADMIN_GROUP_NAME, OIDC_SCOPE

FROM python:3.11-slim

ARG MLFLOW_VERSION=2.17.2

RUN pip install --no-cache-dir \
    mlflow==${MLFLOW_VERSION} \
    psycopg2-binary \
    mlflow-oidc-auth

EXPOSE 5000

ENTRYPOINT ["mlflow", "server", \
    "--host", "0.0.0.0", \
    "--port", "5000", \
    "--app-name", "basic-auth"]
