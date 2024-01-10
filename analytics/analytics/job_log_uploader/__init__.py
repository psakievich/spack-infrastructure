import json
import re
from datetime import datetime
from typing import Any
from celery import shared_task

import gitlab
from opensearch_dsl import Date, Document, connections

from django.conf import settings
from sentry_sdk import set_tag

from analytics import setup_gitlab_job_sentry_tags


class JobLog(Document):
    timestamp = Date()

    class Index:
        name = "gitlab-job-logs-*"

    def save(self, **kwargs):
        # assign now if no timestamp given
        if not self.timestamp:
            self.timestamp = datetime.utcnow()

        # override the index to go to the proper timeslot
        kwargs["index"] = self.timestamp.strftime("gitlab-job-logs-%Y%m%d")
        return super().save(**kwargs)


@shared_task(name="upload_job_log")
def upload_job_log(job_input_data_json: str) -> None:
    job_input_data: dict[str, Any] = json.loads(job_input_data_json)
    setup_gitlab_job_sentry_tags(job_input_data)

    gl = gitlab.Gitlab(settings.GITLAB_ENDPOINT, settings.GITLAB_TOKEN)

    # Retrieve project and job from gitlab API
    project = gl.projects.get(job_input_data["project_id"])
    job = project.jobs.get(job_input_data["build_id"])
    job_trace: str = job.trace().decode()

    # Remove ANSI escape sequences from colorized output
    # TODO: this still leaves trailing ;m in the output
    job_trace = re.sub(
        r"\x1b\[([0-9,A-Z]{1,2}(;[0-9]{1,2})?(;[0-9]{3})?)?[m|G|K]?", "", job_trace
    )

    # Upload to OpenSearch
    connections.create_connection(
        hosts=[settings.OPENSEARCH_ENDPOINT],
        http_auth=(
            settings.OPENSEARCH_USERNAME,
            settings.OPENSEARCH_PASSWORD,
        ),
    )
    doc = JobLog(
        **job_input_data,
        job_url=f'{job_input_data["project"]["web_url"]}/-/jobs/{job_input_data["build_id"]}',
        job_trace=job_trace,
    )
    doc.save()