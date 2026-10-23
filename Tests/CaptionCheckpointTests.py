from pathlib import Path
import runpy
import unittest

measure=runpy.run_path(str(Path(__file__).resolve().parents[1]/"scripts/analyze-caption-checkpoints.py"))["measure"]

class CheckpointTests(unittest.TestCase):
    def fixture(self,delay=0.5,growth=0):
        clips=[];heard=[]
        for i,end in enumerate([4,12,24,36]):
            text=f"phrase{i} starts and ends{i}"
            clips.append({"id":str(i),"reference":text,"end_seconds":end})
            heard.extend((word,end+delay+growth*i/3) for word in text.split())
        return clips,heard

    def test_shared_twenty_second_growth_is_detected_without_a_fast_reference_run(self):
        clips,heard=self.fixture(growth=20)
        r=measure(heard,clips)
        self.assertEqual(r["last_minus_first_quarter_seconds"],20)
        self.assertEqual(r["accumulation_status"],"observed")
        self.assertFalse(r["success"])

    def test_uniform_ten_second_delay_fails_even_without_accumulation(self):
        clips,heard=self.fixture(delay=10)
        r=measure(heard,clips)
        self.assertEqual(r["last_minus_first_quarter_seconds"],0)
        self.assertFalse(r["success"])

    def test_missing_final_quarter_is_not_no_accumulation(self):
        clips,heard=self.fixture()
        r=measure(heard[:-4],clips)
        self.assertEqual(r["accumulation_status"],"insufficient_coverage")
        self.assertFalse(r["success"])

    def test_matching_earlier_words_cannot_substitute_for_missing_final_word(self):
        clips,heard=self.fixture();heard[-1]=("wrong",heard[-1][1])
        r=measure(heard,clips)
        self.assertIn("3",r["missing_utterances"])

    def test_timely_endings_with_both_quarters_pass(self):
        clips,heard=self.fixture()
        self.assertTrue(measure(heard,clips)["success"])

if __name__=="__main__":unittest.main()
