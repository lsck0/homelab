"""The builder's stack handling (scripts/app-builder.py): which file, which builds, which environment.

Usage: app_builder_test.py <path to app-builder.py>
"""
import importlib.util
import os
import sys
import tempfile
import unittest

import yaml

spec = importlib.util.spec_from_file_location("app_builder", sys.argv.pop(1))
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


def write(root, path, text):
    full = os.path.join(root, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w") as f:
        f.write(text)


class Stack(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def test_named_stack_wins(self):
        write(self.repo, "compose.yaml", "services: {a: {image: x}}")
        write(self.repo, "deploy/stack.yaml", "services: {b: {image: y}}")
        stack, stack_dir = builder.load_stack({"stack": "deploy/stack.yaml"}, self.repo)
        self.assertEqual(list(stack["services"]), ["b"])
        self.assertEqual(stack_dir, os.path.join(self.repo, "deploy"))

    def test_conventions_in_order(self):
        write(self.repo, "docker-compose.yml", "services: {late: {image: x}}")
        write(self.repo, "compose.yaml", "services: {early: {image: y}}")
        stack, _ = builder.load_stack({}, self.repo)
        self.assertEqual(list(stack["services"]), ["early"])

    def test_no_compose_file_is_one_image(self):
        stack, stack_dir = builder.load_stack({}, self.repo)
        self.assertEqual(stack, {"services": {"web": {"build": "."}}})
        self.assertEqual(stack_dir, self.repo)

    def test_catalog_build_hint_is_repo_relative(self):
        context, dockerfile, args = builder.build_spec(
            {"image": "wat/server:latest"}, {"context": "services/server", "dockerfile": "services/server/prod.Dockerfile"},
            os.path.join(self.repo, "infrastructure"), self.repo)
        self.assertEqual(context, os.path.join(self.repo, "services/server"))
        self.assertEqual(dockerfile, os.path.join(self.repo, "services/server/prod.Dockerfile"))
        self.assertEqual(args, {})

    def test_compose_build_is_stack_relative(self):
        stack_dir = os.path.join(self.repo, "deploy")
        context, dockerfile, args = builder.build_spec(
            {"build": {"context": "..", "dockerfile": "app.Dockerfile", "args": ["A=1"]}}, None, stack_dir, self.repo)
        self.assertEqual(os.path.normpath(context), self.repo)
        self.assertEqual(os.path.normpath(dockerfile), os.path.join(self.repo, "app.Dockerfile"))
        self.assertEqual(args, {"A": "1"})

    def test_image_only_service_is_not_built(self):
        self.assertIsNone(builder.build_spec({"image": "redis:8"}, None, self.repo, self.repo))

    def test_env_files_inline_and_environment_wins(self):
        write(self.repo, "env/prod.env", "# comment\nA=1\nB='two'\nexport C=3\nPASSWORD=CHANGE_ME\n")
        svc = {"env_file": ["./env/prod.env"], "environment": {"B": "override", "D": None}}
        builder.inline_env(svc, self.repo, self.repo)
        self.assertNotIn("env_file", svc)
        self.assertEqual(svc["environment"], {"A": "1", "B": "override", "C": "3", "PASSWORD": "CHANGE_ME", "D": ""})

    def test_environment_list_form(self):
        svc = {"environment": ["X=1", "Y"]}
        builder.inline_env(svc, self.repo, self.repo)
        self.assertEqual(svc["environment"], {"X": "1", "Y": ""})

    def test_nothing_outside_the_checkout(self):
        for svc, hint in [({"build": {"context": "/run/secrets"}}, None),
                          ({"build": {"context": ".", "dockerfile": "../../etc/passwd"}}, None),
                          ({"image": "x"}, {"context": "/run/secrets"}),
                          ({"image": "x"}, {"context": ".", "dockerfile": "/etc/passwd"})]:
            with self.subTest(svc=svc, hint=hint):
                with self.assertRaises(RuntimeError):
                    builder.build_spec(svc, hint, self.repo, self.repo)
        for env_file in ["/run/secrets/app-deploy-key", "../../outside.env"]:
            with self.subTest(env_file=env_file):
                with self.assertRaises(RuntimeError):
                    builder.inline_env({"env_file": [env_file]}, self.repo, self.repo)
        with self.assertRaises(RuntimeError):
            builder.load_stack({"stack": "../../etc/hosts"}, self.repo)

    def test_metrics_render(self):
        state = self.repo
        builder.write_metrics(state, {"hello": (True, 1700000000), "wat": (False, None)})
        with open(os.path.join(state, "metrics.prom")) as f:
            text = f.read()
        self.assertIn('homelab_app_deploy_ok{app="hello"} 1', text)
        self.assertIn('homelab_app_deploy_ok{app="wat"} 0', text)
        self.assertIn('homelab_app_deploy_last_success_timestamp_seconds{app="hello"} 1700000000', text)
        self.assertNotIn('last_success_timestamp_seconds{app="wat"}', text)


if __name__ == "__main__":
    unittest.main()
