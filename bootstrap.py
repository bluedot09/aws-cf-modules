#!/usr/bin/env python3
import argparse
import logging
import json
from os import path, environ
from sys import exit
import subprocess
from typing import Dict, List
import boto3

log = logging.getLogger(__name__)

REGION = "ap-southeast-2"
SCRIPT_DIR = path.dirname(__file__)
CRITICAL_PATCH = {
    "spec": {
        "template": {
            "spec": {
                "tolerations": [{"key": "CriticalAddonsOnly", "operator": "Exists"}]
            }
        }
    }
}
HOST_NETWORK_PATCH = {"spec": {"template": {"spec": {"hostNetwork": True}}}}
KARPENTER_VERSION = "1.4.0"


def boto3_session(account: str) -> boto3.Session:
    return boto3.Session(profile_name=account)


def get_role_arn(session: boto3.Session, role: str) -> str:
    iam = session.resource("iam")
    response = iam.Role(name=role)
    arn = response.arn
    log.info("%s role arn: %s", role, arn)
    return arn


def kubeconfig_path(cluster: str) -> str:
    return path.join(SCRIPT_DIR, f".kubeconfig-{cluster}-bootstrap")


def kubeconfig_environ(cluster: str) -> Dict[str, str]:
    return {
        **environ,
        "KUBECONFIG": kubeconfig_path(cluster=cluster),
    }


def aws_environ(account: str) -> Dict[str, str]:
    return {**environ, "AWS_PROFILE": account}


def setup_eks_kubeconfig(session: boto3.Session, account: str, cluster: str) -> None:
    env = {**kubeconfig_environ(cluster=cluster), **aws_environ(account=account)}
    cmd = [
        "aws",
        "eks",
        "update-kubeconfig",
        "--name",
        cluster,
        "--alias",
        f"{cluster}-bootstrap",
        "--role-arn",
        get_role_arn(session=session, role="pet_terraform"),
    ]
    try:
        subprocess.check_call(cmd, env=env)
    except subprocess.CalledProcessError:
        exit(1)


def kubectl_run(cluster: str, cmd: List[str]) -> None:
    env = kubeconfig_environ(cluster=cluster)
    subprocess.check_call(["kubectl", *cmd], env=env, cwd=SCRIPT_DIR)


def helm_run(cluster: str, cmd: List[str]) -> None:
    env = kubeconfig_environ(cluster=cluster)
    subprocess.check_call(["helm", *cmd], env=env, cwd=SCRIPT_DIR)


def bootstrap_calico(cluster: str) -> None:
    # remove the AWS CNI
    kubectl_run(
        cluster,
        [
            "--ignore-not-found=true",
            "-n",
            "kube-system",
            "delete",
            "daemonset/aws-node",
        ],
    )
    # install Calico
    kubectl_run(
        cluster=cluster,
        cmd=["apply", "-k", "calico"],
    )

    # un-schedule kube-proxy (current calico handles this properly but why run the pods?)
    # kube_proxy_patch = {
    #     # "spec": {"template": {"spec": {"nodeSelector": {"non-calico": "true"}}}}
    #     # as-documented in Calico AWS guide but seems to break node joining :/
    # }
    # kubectl_patch(
    #     cluster=cluster,
    #     namespace="kube-system",
    #     target="daemonset/kube-proxy",
    #     patch=kube_proxy_patch,
    # )


def install_karpenter(cluster: str) -> None:
    values = {
        "settings.clusterName": cluster,
        # "settings.interruptionQueue": "${cluster}-interruptions",
        "controller.resources.requests.cpu": "200m",
        "controller.resources.requests.memory": "1Gi",
        "controller.resources.limits.cpu": "1500m",
        "controller.resources.limits.memory": "1Gi",
    }
    registry = "public.ecr.aws"
    namespace = "kube-system"
    # helm_run(cluster=cluster, cmd=["registry", "logout", registry])
    log.info(
        "Installing karpenter: %s",
        [i for ii in [["--set", f"{k}={v}"] for k, v in values.items()] for i in ii],
    )
    helm_run(
        cluster=cluster,
        cmd=[
            "upgrade",
            "--install",
            "karpenter",
            f"oci://{registry}/karpenter/karpenter",
            "--version",
            KARPENTER_VERSION,
            "--namespace",
            namespace,
            *[
                i
                for ii in [["--set", f"{k}={v}"] for k, v in values.items()]
                for i in ii
            ],
        ],
    )


def bootstrap_eks_cluster(cluster: str) -> None:
    """
    EKS clusters need a little special-treatment to bring them into line with our
    expectations.

    Setting up the Calico CNI, EBS CSI, etc.

    Once that's done, the usual `bootstrap_cluster(...)`
    """
    bootstrap_calico(cluster=cluster)

    install_karpenter(cluster=cluster)


def kubectl_patch(
    cluster: str, namespace: str, target: str, patch: Dict, patch_type="merge"
) -> None:
    cmd = [
        "-n",
        namespace,
        "patch",
        target,
        f"--type={patch_type}",
        "--patch",
        json.dumps(patch),
    ]
    kubectl_run(cluster=cluster, cmd=cmd)


def bootstrap_cluster(cluster: str) -> None:

    # cert-manager
    kubectl_run(
        cluster=cluster,
        cmd=["apply", "-k", "cert-manager"],
    )
    # patch deployments

    # cattle-cluster-agent (after importing)
    kubectl_patch(
        cluster=cluster,
        namespace="cattle-system",
        target="deployment/cattle-cluster-agent",
        patch=CRITICAL_PATCH,
    )
    # rancher-webhook (after importing)
    kubectl_patch(
        cluster=cluster,
        namespace="cattle-system",
        target="deployment/rancher-webhook",
        patch=CRITICAL_PATCH,
    )
    kubectl_patch(
        cluster=cluster,
        namespace="cattle-system",
        target="deployment/rancher-webhook",
        patch={"spec": {"template": {"spec": {"hostNetwork": True}}}},
    )

    # prometheus

    #


def bootstrap_oneclick(cluster: str, eks: bool) -> None:
    # if eks:
    #     kubectl_run(
    #         cluster=cluster,
    #         cmd=["apply", "-R", "-f", path.join("oneclick", "nodepools")],
    #     )

    # kubectl_run(
    #     cluster=cluster,
    #     cmd=["apply", "-f", path.join("oneclick", "priorityclasses.yaml")],
    # )
    pass


def main():
    parser = argparse.ArgumentParser(
        description="Bootstrap in-cluster resources that already have declarative management like Kubernetes manifests and Helm charts."
    )

    parser.add_argument("--account")
    parser.add_argument("--cluster", required=True)
    parser.add_argument("--oneclick", action="store_true")

    args = parser.parse_args()

    eks = False
    if args.account:
        eks = True
        session = boto3_session(account=args.account)
        setup_eks_kubeconfig(
            session=session, account=args.account, cluster=args.cluster
        )

    if eks:
        bootstrap_eks_cluster(cluster=args.cluster)

    bootstrap_cluster(cluster=args.cluster)

    if args.oneclick:
        bootstrap_oneclick(cluster=args.cluster, eks=eks)


if __name__ == "__main__":
    logging.basicConfig(level=logging.DEBUG)

    # set verbosity down in library dependencies
    for logger in [logging.getLogger(a) for a in ["botocore", "boto3", "urllib3"]]:
        logger.setLevel(logging.WARNING)

    main()
