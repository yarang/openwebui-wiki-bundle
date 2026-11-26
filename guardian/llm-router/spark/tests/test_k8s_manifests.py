#!/usr/bin/env python3
"""Static validation of the k8s/ manifests (PyYAML is a TEST-only
dependency: without it the whole module skips cleanly — the runtime code
is stdlib-only)."""

import os
import re
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

try:
    import yaml
except ImportError:  # pragma: no cover - depends on the host
    raise unittest.SkipTest("PyYAML not installed (test-only dependency)")

import spark_switch  # noqa: E402
import spark_backend_kube as kube  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
PARENT = os.path.dirname(HERE)
K8S = os.path.join(PARENT, "k8s")
PROFILES_PATH = os.path.join(PARENT, "profiles.json")


def load_docs(relpath):
    """All YAML documents of a file under k8s/."""
    with open(os.path.join(K8S, relpath), encoding="utf-8") as f:
        return [d for d in yaml.safe_load_all(f) if d]


def load_one(relpath):
    docs = load_docs(relpath)
    assert len(docs) == 1, f"{relpath}: expected one document, got {len(docs)}"
    return docs[0]


def find_keys(node, keys):
    """Every (key, value) occurrence of `keys`, at any depth."""
    if isinstance(node, dict):
        for k, v in node.items():
            if k in keys:
                yield k, v
            yield from find_keys(v, keys)
    elif isinstance(node, list):
        for item in node:
            yield from find_keys(item, keys)


class KustomizationTests(unittest.TestCase):
    def test_base_resources_all_exist(self):
        k = load_one("base/kustomization.yaml")
        for res in k["resources"]:
            self.assertTrue(
                os.path.exists(os.path.join(K8S, "base", res)),
                f"base/kustomization references missing file: {res}")
        self.assertEqual(
            k["resources"],
            ["namespace.yaml", "rbac.yaml", "hf-cache-pvc.yaml",
             "vllm-deployment.yaml", "vllm-service.yaml",
             "switch-deployment.yaml", "switch-service.yaml"])
        self.assertEqual(k["namespace"], "spark-llm")

    def test_configmap_generator_bundles_the_five_app_files(self):
        k = load_one("base/kustomization.yaml")
        generators = {g["name"]: g for g in k["configMapGenerator"]}
        self.assertIn("spark-switch-app", generators)
        self.assertEqual(
            generators["spark-switch-app"]["files"],
            ["app/spark_switch.py", "app/spark_common.py",
             "app/spark_backend_docker.py", "app/spark_backend_kube.py",
             "app/profiles.json"])

    def test_configmap_literals_select_the_kube_backend(self):
        k = load_one("base/kustomization.yaml")
        generators = {g["name"]: g for g in k["configMapGenerator"]}
        literals = dict(
            item.split("=", 1)
            for g in generators["spark-switch-config"]["literals"]
            for item in [g])
        self.assertEqual(literals["BACKEND"], "kubernetes")
        self.assertEqual(literals["DEFAULT_PROFILE"], "qwen3-instruct")
        self.assertEqual(
            literals["VLLM_URL"], "http://vllm-coder.spark-llm.svc:8000")
        self.assertEqual(literals["K8S_NAMESPACE"], "spark-llm")
        self.assertEqual(literals["K8S_DEPLOYMENT"], "vllm-coder")
        self.assertEqual(literals["K8S_CONTAINER"], "vllm")
        self.assertEqual(literals["K8S_POD_SELECTOR"], "app=vllm-coder")
        self.assertEqual(literals["UNSCHEDULABLE_SECONDS"], "120")
        self.assertEqual(literals["READY_TIMEOUT"], "1800")
        # secrets must arrive via Secret references, never via ConfigMap
        self.assertNotIn("SWITCH_TOKEN", literals)
        self.assertNotIn("VLLM_API_KEY", literals)

    def test_policy_and_device_plugin_are_not_in_the_apply_path(self):
        # the VAP is stage-B optional; the device plugin is its own action.
        for rel in ("base/kustomization.yaml", "overlays/spark/kustomization.yaml"):
            text = open(os.path.join(K8S, rel), encoding="utf-8").read()
            self.assertNotIn("policy/", text)
            self.assertNotIn("device-plugin/", text)

    def test_overlay_pins_pv_patch_and_image_tag(self):
        k = load_one("overlays/spark/kustomization.yaml")
        self.assertEqual(k["resources"], ["../../base", "../../cluster"])
        patch = k["patches"][0]
        self.assertEqual(patch["path"], "hf-cache-pv-patch.yaml")
        self.assertEqual(patch["target"]["kind"], "PersistentVolume")
        self.assertEqual(patch["target"]["name"], "hf-cache")
        self.assertEqual(k["images"],
                         [{"name": "nvcr.io/nvidia/vllm", "newTag": "26.02-py3"}])


class NamespaceTests(unittest.TestCase):
    def test_psa_baseline_enforced(self):
        ns = load_one("base/namespace.yaml")
        self.assertEqual(ns["kind"], "Namespace")
        labels = ns["metadata"]["labels"]
        self.assertEqual(labels["pod-security.kubernetes.io/enforce"],
                         "baseline")
        self.assertEqual(
            labels["pod-security.kubernetes.io/enforce-version"], "latest")


class RbacTests(unittest.TestCase):
    def setUp(self):
        self.docs = {d["kind"]: d for d in load_docs("base/rbac.yaml")}

    def test_role_has_exactly_the_three_least_privilege_rules(self):
        rules = self.docs["Role"]["rules"]
        self.assertEqual(len(rules), 3)
        by_resource = {tuple(r["resources"]): r for r in rules}
        deploy = by_resource[("deployments",)]
        self.assertEqual(deploy["apiGroups"], ["apps"])
        self.assertEqual(deploy["verbs"], ["get", "patch"])
        self.assertEqual(deploy["resourceNames"], ["vllm-coder"])
        pods = by_resource[("pods",)]
        self.assertEqual(pods["apiGroups"], [""])
        self.assertEqual(sorted(pods["verbs"]), ["get", "list", "watch"])
        self.assertNotIn("resourceNames", pods)  # list cannot be name-scoped
        logs = by_resource[("pods/log",)]
        self.assertEqual(logs["verbs"], ["get"])

    def test_no_wildcards_or_dangerous_verbs(self):
        for rule in self.docs["Role"]["rules"]:
            self.assertNotIn("*", rule["verbs"])
            self.assertNotIn("*", rule.get("resources", []))
            for verb in rule["verbs"]:
                self.assertNotIn(verb, ("create", "delete", "deletecollection",
                                        "impersonate", "bind", "escalate"))

    def test_rolebinding_wires_the_service_account(self):
        rb = self.docs["RoleBinding"]
        self.assertEqual(rb["roleRef"]["kind"], "Role")
        self.assertEqual(rb["roleRef"]["name"], "spark-switch")
        subject = rb["subjects"][0]
        self.assertEqual(subject["kind"], "ServiceAccount")
        self.assertEqual(subject["name"], "spark-switch")
        self.assertEqual(subject["namespace"], "spark-llm")
        sa = self.docs["ServiceAccount"]
        self.assertEqual(sa["metadata"]["name"], "spark-switch")


class VllmDeploymentTests(unittest.TestCase):
    def setUp(self):
        self.dep = load_one("base/vllm-deployment.yaml")
        self.spec = self.dep["spec"]
        self.template = self.spec["template"]
        self.podspec = self.template["spec"]
        self.container = self.podspec["containers"][0]
        self.assertEqual(len(self.podspec["containers"]), 1)

    def test_rollout_shape(self):
        self.assertEqual(self.spec["replicas"], 1)
        self.assertEqual(self.spec["strategy"]["type"], "Recreate")
        # READY_TIMEOUT is 1800 s; the k8s default deadline (600) would
        # mark a healthy first load failed.
        self.assertEqual(self.spec["progressDeadlineSeconds"], 2400)
        self.assertEqual(self.spec["selector"]["matchLabels"],
                         {"app": "vllm-coder"})

    def test_pod_spec_hardening(self):
        self.assertEqual(self.podspec["runtimeClassName"], "nvidia")
        self.assertIs(self.podspec["enableServiceLinks"], False)
        self.assertIs(self.podspec["automountServiceAccountToken"], False)
        self.assertEqual(self.podspec["terminationGracePeriodSeconds"], 60)
        self.assertNotIn("serviceAccountName", self.podspec)

    def test_container_args_equal_pod_args_of_the_default_profile(self):
        profiles = spark_switch.load_profiles(PROFILES_PATH)
        self.assertEqual(
            self.container["args"], kube.pod_args(profiles["qwen3-instruct"]))
        self.assertEqual(self.container["command"], ["vllm", "serve"])
        self.assertEqual(self.container["image"],
                         "nvcr.io/nvidia/vllm:26.02-py3")
        self.assertEqual(self.container["imagePullPolicy"], "IfNotPresent")

    def test_template_annotation_names_the_profile(self):
        self.assertEqual(self.template["metadata"]["annotations"]
                         ["spark-switch/profile"], "qwen3-instruct")

    def test_api_key_comes_from_a_secret_ref(self):
        env = {e["name"]: e for e in self.container["env"]}
        ref = env["VLLM_API_KEY"]["valueFrom"]["secretKeyRef"]
        self.assertEqual(ref["name"], "vllm-api-key")
        self.assertEqual(ref["key"], "VLLM_API_KEY")
        self.assertNotIn("value", env["VLLM_API_KEY"])

    def test_resources_one_gpu_no_memory_limit(self):
        res = self.container["resources"]
        self.assertEqual(res["requests"], {"cpu": "2", "memory": "4Gi"})
        self.assertEqual(res["limits"], {"nvidia.com/gpu": 1})
        self.assertNotIn("memory", res["limits"])

    def test_volumes(self):
        mounts = {v["name"]: v for v in self.container["volumeMounts"]}
        self.assertEqual(mounts["hf-cache"]["mountPath"],
                         "/root/.cache/huggingface")
        vols = {v["name"]: v for v in self.podspec["volumes"]}
        self.assertEqual(vols["hf-cache"]["persistentVolumeClaim"]
                         ["claimName"], "hf-cache")
        dshm = vols["dshm"]["emptyDir"]
        self.assertEqual(dshm["medium"], "Memory")
        self.assertEqual(dshm["sizeLimit"], "8Gi")

    def test_probes_hit_health_on_8000(self):
        probes = {name: self.container[f"{name}Probe"]
                  for name in ("startup", "liveness", "readiness")}
        for name, probe in probes.items():
            self.assertEqual(probe["httpGet"]["path"], "/health",
                             f"{name} probe path")
            self.assertEqual(probe["httpGet"]["port"], 8000, f"{name} port")
        self.assertEqual(probes["startup"]["periodSeconds"], 10)
        self.assertEqual(probes["startup"]["failureThreshold"], 180)
        self.assertEqual(probes["liveness"]["periodSeconds"], 30)
        self.assertEqual(probes["liveness"]["failureThreshold"], 5)
        self.assertEqual(probes["readiness"]["periodSeconds"], 10)


class SwitchDeploymentTests(unittest.TestCase):
    def setUp(self):
        self.dep = load_one("base/switch-deployment.yaml")
        self.podspec = self.dep["spec"]["template"]["spec"]
        self.container = self.podspec["containers"][0]

    def test_uses_the_rbac_identity(self):
        self.assertEqual(self.podspec["serviceAccountName"], "spark-switch")
        self.assertIs(self.podspec["automountServiceAccountToken"], True)
        self.assertEqual(self.dep["spec"]["strategy"]["type"], "Recreate")

    def test_config_comes_from_configmap_secrets_from_secret(self):
        self.assertEqual(self.container["envFrom"][0]["configMapRef"]
                         ["name"], "spark-switch-config")
        env = {e["name"]: e for e in self.container["env"]}
        for name, secret, key in (("SWITCH_TOKEN", "spark-switch-token",
                                   "SWITCH_TOKEN"),
                                  ("VLLM_API_KEY", "vllm-api-key",
                                   "VLLM_API_KEY")):
            ref = env[name]["valueFrom"]["secretKeyRef"]
            self.assertEqual((ref["name"], ref["key"]), (secret, key))
            self.assertNotIn("value", env[name])
        self.assertEqual(self.container["command"],
                         ["python3", "/app/spark_switch.py"])

    def test_small_footprint_and_hardened_container(self):
        res = self.container["resources"]
        self.assertEqual(res["requests"], {"cpu": "50m", "memory": "128Mi"})
        self.assertEqual(res["limits"], {"memory": "512Mi"})
        sc = self.container["securityContext"]
        self.assertIs(sc["allowPrivilegeEscalation"], False)
        self.assertEqual(sc["capabilities"]["drop"], ["ALL"])
        mounts = self.container["volumeMounts"][0]
        self.assertEqual((mounts["name"], mounts["mountPath"],
                          mounts["readOnly"]), ("app", "/app", True))
        self.assertEqual(self.podspec["volumes"][0]["configMap"]["name"],
                         "spark-switch-app")

    def test_probes_and_port(self):
        self.assertEqual(self.container["ports"][0]["containerPort"], 8010)
        for name in ("readiness", "liveness"):
            probe = self.container[f"{name}Probe"]
            self.assertEqual(probe["httpGet"]["path"], "/health")
            self.assertEqual(probe["httpGet"]["port"], 8010)


class ServiceTests(unittest.TestCase):
    def test_both_services_are_loadbalancers_on_the_docker_ports(self):
        for rel, name, port in (("base/vllm-service.yaml", "vllm-coder", 8000),
                                ("base/switch-service.yaml", "spark-switch",
                                 8010)):
            svc = load_one(rel)
            self.assertEqual(svc["metadata"]["name"], name)
            self.assertEqual(svc["spec"]["type"], "LoadBalancer")
            self.assertEqual(svc["spec"]["selector"],
                             {"app": name} if name == "spark-switch"
                             else {"app": "vllm-coder"})
            self.assertEqual(svc["spec"]["ports"][0]["port"], port)
            self.assertEqual(svc["spec"]["ports"][0]["targetPort"], port)


class StorageTests(unittest.TestCase):
    def test_pvc_binds_the_pre_existing_pv(self):
        pvc = load_one("base/hf-cache-pvc.yaml")
        spec = pvc["spec"]
        self.assertEqual(spec["storageClassName"], "")
        self.assertEqual(spec["volumeName"], "hf-cache")
        self.assertEqual(spec["accessModes"], ["ReadWriteOnce"])
        self.assertEqual(spec["resources"]["requests"]["storage"], "500Gi")

    def test_pv_is_retained_cluster_scoped_and_placeholderd(self):
        pv = load_one("cluster/hf-cache-pv.yaml")
        self.assertIsNone(pv["metadata"].get("namespace"))  # cluster-scoped
        spec = pv["spec"]
        self.assertEqual(spec["persistentVolumeReclaimPolicy"], "Retain")
        self.assertEqual(spec["storageClassName"], "")
        self.assertEqual(spec["claimRef"], {"namespace": "spark-llm",
                                            "name": "hf-cache"})
        self.assertEqual(spec["capacity"]["storage"], "500Gi")
        # the repo keeps a placeholder; only the installer's staged copy
        # carries the real path
        self.assertEqual(spec["hostPath"]["path"],
                         "/home/YOUR_USER/.cache/huggingface")
        self.assertEqual(spec["hostPath"]["type"], "Directory")

    def test_pv_patch_only_touches_the_hostpath(self):
        patch = load_one("overlays/spark/hf-cache-pv-patch.yaml")
        self.assertEqual(patch["metadata"]["name"], "hf-cache")
        self.assertEqual(list(patch["spec"].keys()), ["hostPath"])
        self.assertEqual(patch["spec"]["hostPath"]["path"],
                         "/home/YOUR_USER/.cache/huggingface")


class DevicePluginTests(unittest.TestCase):
    def setUp(self):
        self.rc = load_one("device-plugin/runtimeclass-nvidia.yaml")
        self.ds = load_one("device-plugin/nvidia-device-plugin.yaml")

    def test_runtimeclass_uses_nvidia_handler(self):
        self.assertEqual(self.rc["handler"], "nvidia")

    def test_daemonset_pinned_to_v0_17_4(self):
        # GB10 reports point to v0.17.4; v0.18.0 with driver 580.95.05 is
        # known-broken (design §9). The tag must be pinned, never floating.
        image = self.ds["spec"]["template"]["spec"]["containers"][0]["image"]
        self.assertEqual(image, "nvcr.io/nvidia/k8s-device-plugin:v0.17.4")
        self.assertNotIn("latest", image)

    def test_daemonset_pins_image_pull_policy_if_not_present(self):
        # offline installs import the plugin image into containerd ahead of
        # time; without an explicit policy k8s defaults to Always for
        # non-:latest tags and every air-gapped node would try the registry
        container = self.ds["spec"]["template"]["spec"]["containers"][0]
        self.assertEqual(container["imagePullPolicy"], "IfNotPresent")

    def test_daemonset_shape(self):
        self.assertEqual(self.ds["metadata"]["namespace"], "kube-system")
        spec = self.ds["spec"]["template"]["spec"]
        self.assertEqual(spec["runtimeClassName"], "nvidia")
        self.assertEqual(spec["priorityClassName"], "system-node-critical")
        tolerations = spec["tolerations"]
        self.assertEqual(tolerations[0]["key"], "nvidia.com/gpu")
        self.assertEqual(tolerations[0]["operator"], "Exists")
        env = {e["name"]: e for e in spec["containers"][0]["env"]}
        self.assertEqual(env["FAIL_ON_INIT_ERROR"]["value"], "false")
        self.assertEqual(spec["volumes"][0]["hostPath"]["path"],
                         "/var/lib/kubelet/device-plugins")


class OfflinePatchTests(unittest.TestCase):
    """The OFFLINE=1 air-gap env patch: injected into the STAGED overlay by
    install-spark-k8s.sh, never referenced by the repo overlay itself."""

    def setUp(self):
        self.path = os.path.join(K8S, "overlays", "spark",
                                 "offline-env-patch.yaml")
        with open(self.path, encoding="utf-8") as f:
            self.text = f.read()
        self.patch = yaml.safe_load(self.text)

    def test_patch_targets_the_vllm_coder_container(self):
        # strategic-merge on the Deployment; the container list merges by name
        self.assertEqual(self.patch["apiVersion"], "apps/v1")
        self.assertEqual(self.patch["kind"], "Deployment")
        self.assertEqual(self.patch["metadata"]["name"], "vllm-coder")
        container = self.patch["spec"]["template"]["spec"]["containers"][0]
        self.assertEqual(container["name"], "vllm")

    def test_patch_sets_exactly_the_three_offline_env_vars(self):
        container = self.patch["spec"]["template"]["spec"]["containers"][0]
        env = {e["name"]: e["value"] for e in container["env"]}
        self.assertEqual(env, {
            "HF_HUB_OFFLINE": "1",
            "TRANSFORMERS_OFFLINE": "1",
            "TIKTOKEN_ENCODINGS_BASE":
                "/root/.cache/huggingface/tiktoken"})

    def test_patch_carries_no_secret_material(self):
        for secret in ("SWITCH_TOKEN", "VLLM_API_KEY", "HF_TOKEN"):
            self.assertNotIn(secret + "=", self.text)
        # compound secret-ish names (plain "token" would hit TIKTOKEN_ENCODINGS)
        self.assertNotRegex(
            self.text,
            r"(?i)(switch[_-]?token|api[_-]?key|password|hf[_-]?token)")

    def test_repo_overlay_does_not_reference_the_offline_patch(self):
        # the shipped overlay stays ONLINE by default; only the staged copy
        # (install-spark-k8s.sh with OFFLINE=1) may reference the patch
        with open(os.path.join(K8S, "overlays", "spark",
                               "kustomization.yaml"), encoding="utf-8") as f:
            overlay_text = f.read()
        self.assertNotIn("offline-env-patch.yaml", overlay_text)


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.text = open(os.path.join(K8S, "policy/vap-spark-switch.yaml"),
                         encoding="utf-8").read()
        self.docs = {d["kind"]: d for d in load_docs("policy/vap-spark-switch.yaml")}
        self.vap = self.docs["ValidatingAdmissionPolicy"]
        # all validation expressions + messages, joined for substring checks
        self.joined = "\n".join(
            v["expression"] + "\n" + v.get("message", "")
            for v in self.vap["spec"]["validations"])

    def test_policy_matches_only_the_controller_sa(self):
        rules = self.vap["spec"]["matchConstraints"]["resourceRules"]
        self.assertEqual(rules[0]["resources"], ["deployments"])
        self.assertEqual(rules[0]["operations"], ["UPDATE"])
        cond = self.vap["spec"]["matchConditions"][0]
        self.assertIn("system:serviceaccount:spark-llm:spark-switch",
                      cond["expression"])
        self.assertEqual(self.vap["spec"]["failurePolicy"], "Fail")

    def test_every_advertised_field_is_pinned_by_some_validation(self):
        # there is no apiserver here, so the allowlist is asserted
        # structurally: every field the header comment promises to pin must
        # appear in a `?field == ?field` (or container-level o.?f == c.?f)
        # comparison, and args must NOT be compared (only args may differ).
        # G2: the pod-spec list is the WHOLE core/v1 PodSpec surface except
        # `containers` (pinned by the container validation above).
        pod_spec_fields = (
            "initContainers", "ephemeralContainers", "volumes",
            "hostAliases", "dnsConfig", "dnsPolicy", "shareProcessNamespace",
            "hostUsers", "hostname", "subdomain", "setHostnameAsFQDN",
            "restartPolicy", "terminationGracePeriodSeconds",
            "activeDeadlineSeconds", "schedulerName", "imagePullSecrets",
            "readinessGates", "overhead", "os", "preemptionPolicy",
            "priority", "topologySpreadConstraints", "schedulingGates",
            "resourceClaims", "serviceAccountName", "runtimeClassName",
            "nodeName", "nodeSelector", "tolerations", "affinity",
            "securityContext", "hostNetwork", "hostPID", "hostIPC",
            "automountServiceAccountToken", "enableServiceLinks",
            "priorityClassName")
        for field in pod_spec_fields:
            self.assertIn(
                f"object.spec.template.spec.?{field} ==",
                self.joined, f"pod spec field not pinned: {field}")
            self.assertIn(
                f"oldObject.spec.template.spec.?{field}",
                self.joined, f"pod spec field not compared against old: {field}")
        # G1: the container list is the WHOLE core/v1 Container surface
        # except args (free) and name (the join key).
        container_fields = (
            "command", "env", "envFrom", "volumeMounts", "volumeDevices",
            "resources", "resizePolicy", "restartPolicy", "securityContext",
            "ports", "livenessProbe", "readinessProbe", "startupProbe",
            "lifecycle", "workingDir", "imagePullPolicy",
            "terminationMessagePath", "terminationMessagePolicy",
            "stdin", "stdinOnce", "tty")
        for field in container_fields:
            self.assertIn(f"o.?{field} == c.?{field}", self.joined,
                          f"container field not pinned: {field}")
        # image is a required field: compared without the optional marker
        self.assertIn("o.image == c.image", self.joined)
        self.assertIn("o.name == c.name", self.joined)
        # G1: the container set is pinned SYMMETRICALLY — every OLD
        # container must survive by name in the new object, so containers
        # can be neither added nor removed/renamed, only args-rewritten.
        self.assertIn(
            "oldObject.spec.template.spec.containers.all(o,",
            self.joined)
        self.assertIn(
            "object.spec.template.spec.containers.exists(c, c.name == o.name)",
            self.joined)
        # deployment-level
        for expr in ("object.spec.?replicas == oldObject.spec.?replicas",
                     "object.spec.?strategy == oldObject.spec.?strategy",
                     "object.spec.selector == oldObject.spec.selector",
                     "object.spec.template.metadata.?labels == "
                     "oldObject.spec.template.metadata.?labels"):
            self.assertIn(expr, self.joined)
        # args are the ONE container field that must stay free
        self.assertNotIn("o.?args == c.?args", self.joined)
        self.assertNotIn("o.args == c.args", self.joined)

    def test_annotation_rule_names_exactly_the_allowed_keys(self):
        annotations = [v for v in self.vap["spec"]["validations"]
                       if "annotations" in v["expression"]]
        self.assertEqual(len(annotations), 1)
        expr = annotations[0]["expression"]
        # exactly the two allowed keys, nothing else, are named
        literals = re.findall(r"'([^']*)'", expr)
        self.assertEqual(
            sorted(literals),
            ["spark-switch/profile", "spark-switch/profile",
             "spark-switch/requested-at", "spark-switch/requested-at"])
        # restartedAt is deliberately NOT allowed; the header comment
        # documents the decision, the expression must not name it
        self.assertNotIn("restartedAt", expr)
        self.assertIn("restartedAt", self.text)  # ...and the decision is
        # documented in the file header

    def test_annotation_rule_cannot_short_circuit_added_keys(self):
        # G3: an arm like `!(k in oldAnnotations)` is TRUE for every key the
        # old template did not have, so any newly ADDED annotation
        # (kubectl.kubernetes.io/restartedAt included) would pass. The
        # intended rule is default-deny: a new key must be one of the two
        # allowed keys, or already exist in the old annotations with the
        # SAME value. There is no apiserver here, so the rule is pinned
        # structurally on the expression text.
        annotations = [v for v in self.vap["spec"]["validations"]
                       if "annotations" in v["expression"]]
        self.assertEqual(len(annotations), 1)
        expr = annotations[0]["expression"]
        # the short-circuit pattern must not appear anywhere
        self.assertNotIn("!(k in", expr)
        # new-annotations direction: membership in the ALLOWLIST is the
        # first arm (parenthesised, so it cannot be bypassed)...
        self.assertIn(
            "(k == 'spark-switch/profile' "
            "|| k == 'spark-switch/requested-at')",
            expr)
        # ...and the only other escape for a key is being present in the
        # old annotations with an equal value
        self.assertIn(
            "k in oldObject.spec.template.metadata.?annotations.orValue({})",
            expr)
        self.assertIn(
            "oldObject.spec.template.metadata.?annotations.orValue({})[k] == "
            "object.spec.template.metadata.?annotations.orValue({})[k]",
            expr)
        # old-annotations direction: a key may only disappear when allowed
        self.assertIn(
            "k in object.spec.template.metadata.?annotations.orValue({})",
            expr)

    def test_stage_b_behavioural_check_is_documented(self):
        self.assertIn("--as=system:serviceaccount:spark-llm:spark-switch",
                      self.text)
        self.assertIn("--dry-run=server", self.text)
        self.assertIn("FORBIDDEN", self.text)

    def test_binding_denies(self):
        binding = self.docs["ValidatingAdmissionPolicyBinding"]
        self.assertEqual(binding["spec"]["policyName"], "spark-switch-limits")
        self.assertEqual(binding["spec"]["validationActions"], ["Deny"])
        self.assertEqual(
            binding["spec"]["matchResources"]["namespaceSelector"]
            ["matchLabels"],
            {"kubernetes.io/metadata.name": "spark-llm"})


class SecurityScanTests(unittest.TestCase):
    """Recursive scans over the manifests that describe spark-llm workloads
    (the device plugin in kube-system legitimately needs hostPath)."""

    WORKLOADS = ("base/vllm-deployment.yaml", "base/switch-deployment.yaml")

    def test_no_host_access_in_workload_pod_specs(self):
        banned = {"hostPath", "hostNetwork", "hostPID", "hostIPC", "hostPort"}
        for rel in self.WORKLOADS:
            podspec = load_one(rel)["spec"]["template"]["spec"]
            found = list(find_keys(podspec, banned))
            self.assertEqual(found, [], f"{rel}: host access found: {found}")

    def test_no_privileged_containers_or_added_capabilities(self):
        for rel in self.WORKLOADS:
            podspec = load_one(rel)["spec"]["template"]["spec"]
            for container in podspec["containers"]:
                sc = container.get("securityContext") or {}
                self.assertNotIn("privileged", sc, f"{rel}: privileged")
                self.assertNotIn("add", sc.get("capabilities") or {},
                                 f"{rel}: capabilities.add")

    def test_no_plaintext_secrets_in_any_manifest(self):
        for root, _, files in os.walk(K8S):
            for fname in files:
                if not fname.endswith((".yaml", ".yml")):
                    continue
                path = os.path.join(root, fname)
                for doc in load_docs(os.path.relpath(path, K8S)):
                    self.assertNotEqual(doc.get("kind"), "Secret",
                                        f"{path}: Secret must be created by "
                                        "the installer, not committed")
                    for key, value in find_keys(doc, {"stringData", "data"}):
                        self.fail(f"{path}: {key} block (possible plaintext "
                                  f"secret): {key}")
                text = open(path, encoding="utf-8").read()
                for marker in ("VLLM_API_KEY=sk", "SWITCH_TOKEN="):
                    if marker in text.replace(
                            "SWITCH_TOKEN=change-me-to-a-long-random-value",
                            ""):
                        self.fail(f"{path}: possible literal secret near "
                                  f"{marker!r}")


if __name__ == "__main__":
    unittest.main()
