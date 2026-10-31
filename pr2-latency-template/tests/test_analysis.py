import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('analysis',Path(__file__).resolve().parents[1]/'scripts'/'analyze_latency.py')
analysis=importlib.util.module_from_spec(spec); spec.loader.exec_module(analysis)


def event(index,sample,status,rtt='',srtt='',sent='0',received='0'):
    return dict(experiment_id='test',run_id='one',event_index=str(index),sample=str(sample),status=status,
                rtt_ms=str(rtt),srtt_ms=str(srtt),sent_at_ms=sent,received_at_ms=received,attempts='1')


class AnalysisTests(unittest.TestCase):
    def test_event_log_does_not_double_count_loss_or_duplicates(self):
        rows=[event(1,1,'received',100,100,received='100'),event(2,1,'duplicate_response'),
              event(3,2,'timeout'),event(4,2,'late_response')]
        metric,_=analysis.analyze_rows(rows)[0]
        self.assertEqual((metric['sent'],metric['received'],metric['timeouts'],metric['late']),(2,1,1,1))
        self.assertEqual(metric['loss_percent'],50)

    def test_corrupted_or_double_terminal_rows_are_rejected(self):
        with self.assertRaises(ValueError):
            analysis.analyze_rows([event(1,1,'received',100,100,received='100'),event(2,1,'timeout')])
        with self.assertRaises(ValueError):
            analysis.analyze_rows([event(1,1,'received','nan',100)])
        with self.assertRaises(ValueError):
            analysis.analyze_rows([event(1,1,'late_response')])
        with self.assertRaises(ValueError):
            analysis.analyze_rows([event(1,1,'received',100,90,received='100')])


if __name__=='__main__': unittest.main()
