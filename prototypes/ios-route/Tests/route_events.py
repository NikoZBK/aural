"""Checks that evidence gaps and unrelated route failures cannot become a pass."""
import importlib.util
from datetime import datetime, timedelta
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "route_events", Path(__file__).parents[1] / "scripts" / "route-events.py")
route_events = importlib.util.module_from_spec(spec)
spec.loader.exec_module(route_events)


class RouteEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.time = datetime.fromisoformat("2026-10-10T18:04:41-04:00")
        self.context = (self.time, "audiomxd",
                        "doesn't support currently selected protocolID " + route_events.PROTOCOL)
        self.failure = (self.time + timedelta(seconds=1.5), "audiomxd",
                        "MDE fallback to local: mediaIsPlaying=YES")

    def test_correlated_failure_and_overlapping_exports(self):
        result = route_events.summarize([self.failure, self.context, self.failure])
        self.assertEqual(result["verdict"], "OBSERVED_AURAL_ROUTE_REVERSION")
        self.assertEqual(len(result["failure_times"]), 1)

    def test_missing_context_is_inconclusive(self):
        for events in ([], [self.context], [self.failure]):
            with self.subTest(events=events):
                self.assertEqual(route_events.summarize(events)["verdict"], "INCONCLUSIVE")

    def test_lifecycle_evidence_is_retained_without_inventing_a_pass(self):
        messages = ["HAL withdrawal notified: device list is empty status=0",
                    "Restoring HAL device list for registration.",
                    "HAL withdrawal notification failed: status=-1"]
        events = [(self.time + timedelta(seconds=i), "AuralRouteExtension", message)
                  for i, message in enumerate(messages)]
        result = route_events.summarize(events)
        self.assertEqual([event["message"] for event in result["timeline"]], messages)
        self.assertEqual(result["verdict"], "INCONCLUSIVE")

    def test_unrelated_route_is_inconclusive(self):
        context = (self.time, "audiomxd", self.context[2].replace(route_events.PROTOCOL, "other.protocol"))
        self.assertEqual(route_events.summarize([context, self.failure])["verdict"], "INCONCLUSIVE")

    def test_old_or_future_context_cannot_attribute_failure(self):
        for offset in (-4, 4):
            context = (self.time + timedelta(seconds=offset), *self.context[1:])
            self.assertEqual(route_events.summarize([context, self.failure])["verdict"], "INCONCLUSIVE")

    def test_timezone_required_in_structured_export(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "events.ndjson"
            path.write_text('{"timestamp":"2026-10-10 18:04:43","eventMessage":"MDE fallback to local"}\n')
            with self.assertRaisesRegex(ValueError, "timezone"):
                route_events.read_events(path, None)


if __name__ == "__main__":
    unittest.main()
