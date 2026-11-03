Create a GCP Secret Manager Uploader
Using FastAPI with SQLite as a backend that can be swapped for postgresql.
Use SQLModel
* User must supply the GCP Project ID, Secret Endpoint and Secret ( as a file )
  * A success code, and the sha256sum as well as the full path to the secret returned.
  * Uploaded secret must not be written to disk.
* User can supply project ID, secret endpoint, secret will be downloaded, sha256sum computed and return if exists.
* Will be hosted on GKE Kubernetes
* User can login with GCP Auth Token
* Secret uploaded via the Kubernetes Service Account Authentication.
* Microservice will be dockerized.
* at least python 3.13
* Managed using uv in Docker container
* Langgraph will be used to maintain the state, resumable workflow.
