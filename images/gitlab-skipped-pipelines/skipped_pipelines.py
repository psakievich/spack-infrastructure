#!/usr/bin/env python

import json
import os
import re
import urllib.parse

import requests


GITLAB_API_URL = "https://gitlab.spack.io/api/v4/projects/2"
AUTH_HEADER = {
    "PRIVATE-TOKEN": os.environ.get("GITLAB_TOKEN", None)
}


def paginate(query_url):
    """Helper method to get all pages of paginated query results"""
    results = []

    while query_url:
        resp = requests.get(query_url, headers=AUTH_HEADER)

        if resp.status_code == 401:
            print(" !!! Unauthorized to make request, check GITLAB_TOKEN !!!")
            return []

        next_batch = json.loads(resp.content)

        for result in next_batch:
            results.append(result)

        if "next" in resp.links:
            query_url = resp.links["next"]["url"]
        else:
            query_url = None

    return results


def print_response(resp, padding=''):
    """Helper method to print response status code and content"""
    print(f"{padding}response code: {resp.status_code}")
    print(f"{padding}response value: {resp.text}")


def run_new_pipeline(pipeline_ref):
    """Given a ref (branch name), run a new pipeline for that ref.  If
    the branch has already been deleted from gitlab, this will generate
    an error and a 400 response, but we probably don't care."""
    enc_ref = urllib.parse.quote_plus(pipeline_ref)
    run_url = f"{GITLAB_API_URL}/pipeline?ref={enc_ref}"
    print(f"    !!!! running new pipeline for {pipeline_ref}")
    print_response(requests.post(run_url, headers=AUTH_HEADER), "      ")


def find_and_run_skipped_pipelines():
    """Query gitlab for all branches. Start a pipeline for any branch whose
    HEAD commit does not already have one.
    """
    print(f"Attempting to find & fix skipped pipelines")
    branches_url = f"{GITLAB_API_URL}/repository/branches"
    branches = paginate(branches_url)
    print(f"Found {len(branches)} branches")

    regexp = re.compile("pr([0-9]+)")
    for branch in branches:
        branch_name = branch["name"]
        m = regexp.search(branch_name)
        if not m:
            print(f"Not a PR branch: {branch_name}")
            continue
        branch_commit = branch["commit"]["id"]
        pipelines_url = f"{GITLAB_API_URL}/pipelines?sha={branch_commit}"
        pipelines = paginate(pipelines_url)
        if len(pipelines) == 0:
            run_new_pipeline(branch_name)
        else:
            print(f"no need to run a new pipeline for {branch_name}")


if __name__ == "__main__":
    if "GITLAB_TOKEN" not in os.environ:
        raise Exception("GITLAB_TOKEN environment is not set")
    try:
        find_and_run_skipped_pipelines()
    except Exception as inst:
        print("Caught unhandled exception:")
        print(inst)