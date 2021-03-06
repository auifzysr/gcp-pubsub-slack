provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

data "google_project" "project" {
}

locals {
  resource_name = "${var.resource_name_prefix}-${var.env}"
}

resource "google_service_account" "cloudrun_sa" {
  account_id   = local.resource_name
  display_name = local.resource_name
}

resource "google_project_iam_binding" "pubsub_sa_roles_token_creator" {
  project = data.google_project.project.project_id
  role    = "roles/iam.serviceAccountTokenCreator"
  members = [
    "serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
  ]

  depends_on = [
    google_service_account.cloudrun_sa,
  ]
}

resource "google_cloud_run_service" "pubsub-slack" {
  name     = local.resource_name
  location = var.region

  metadata {
    annotations = {
      "run.googleapis.com/launch-stage"  = "BETA"
      "run.googleapis.com/ingress"       = "all"
      "autoscaling.knative.dev/maxScale" = "1"
    }
  }
  template {
    spec {
      containers {
        image = "gcr.io/${data.google_project.project.project_id}/${local.resource_name}:init"
        env {
          name  = "SLACK_TOKEN"
          value = var.slack_token
        }
        env {
          name  = "SLACK_CHANNEL"
          value = var.slack_channel
        }
        resources {
          limits = {
            memory = "128Mi"
            cpu    = "100m"
          }
        }
      }
      container_concurrency = 1
      timeout_seconds       = 60
    }
  }

  autogenerate_revision_name = true

  traffic {
    percent         = 100
    latest_revision = true
  }

  timeouts {
    create = "2m"
    update = "2m"
    delete = "2m"
  }

  depends_on = [
    google_project_iam_binding.pubsub_sa_roles_token_creator
  ]
}

resource "google_cloud_run_service_iam_binding" "cloudrun_sa_roles_invoker" {
  location = var.region
  project  = data.google_project.project.project_id
  role     = "roles/run.invoker"
  service  = google_cloud_run_service.pubsub-slack.name
  members = [
    "serviceAccount:${google_service_account.cloudrun_sa.email}"
  ]

  depends_on = [
    google_cloud_run_service.pubsub-slack,
  ]
}

resource "google_pubsub_topic" "pubsub-slack" {
  name = local.resource_name
}

resource "google_pubsub_subscription" "pubsub-slack" {
  name  = local.resource_name
  topic = google_pubsub_topic.pubsub-slack.name

  ack_deadline_seconds = 600
  push_config {
    oidc_token {
      service_account_email = google_service_account.cloudrun_sa.email
    }
    push_endpoint = google_cloud_run_service.pubsub-slack.status[0].url
  }

  depends_on = [
    google_pubsub_topic.pubsub-slack,
    google_project_iam_binding.pubsub_sa_roles_token_creator,
  ]
}

resource "google_pubsub_subscription_iam_member" "push_auth" {
  subscription = google_pubsub_subscription.pubsub-slack.name
  role         = "roles/editor"
  member       = "serviceAccount:${google_service_account.cloudrun_sa.email}"

  depends_on = [
    google_pubsub_subscription.pubsub-slack,
  ]
}

resource "google_cloudbuild_trigger" "pubsub-slack" {
  name        = local.resource_name
  description = "build and deploy ${local.resource_name}"
  trigger_template {
    branch_name = var.env
    repo_name   = "gcp-pubsub-slack"
  }

  substitutions = {
    _SLACK_TOKEN   = var.slack_token
    _SLACK_CHANNEL = var.slack_channel
  }

  included_files = ["src/**"]

  filename = "cloudbuild.yaml"
}
