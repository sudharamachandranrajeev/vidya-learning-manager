/// The job dossier's device pieces: the polite gate the readers share, the
/// readers the learner's own keys turn on, and each journey's cards and
/// sources. Tests override the web client with recorded fixtures.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:brahma_core/brahma_core.dart';

import '../db/database.dart';
import '../domain/dossier_book.dart';
import '../domain/interview.dart' show InterviewTraining;
import '../domain/dossier_readers.dart';
import 'providers.dart';

/// One gate for the life of the app, so its gap between requests to a
/// site holds across readers. Its cache is a device-only setting.
final researchGateProvider = Provider<PoliteGate>((ref) {
  final db = ref.watch(sessionProvider).db;
  return PoliteGate(
    ref.watch(httpClientProvider),
    cacheRead: db.localSetting,
    cacheWrite: db.setLocalSetting,
  );
});

/// The CQC and Companies House readers, each null until its key is added.
final keyedReadersProvider = FutureProvider<({CqcReader? cqc, CompaniesHouseReader? companiesHouse})>(
  (ref) => keyedReaders(ref.watch(sessionProvider).keys.store, ref.watch(researchGateProvider)),
);

typedef DossierData = ({List<FactCard> cards, List<FactSource> sources});

/// A program's dossier, read again after every write.
final dossierProvider = FutureProvider.family<DossierData, String>((ref, programId) async {
  ref.watch(revisionProvider);
  final book = ref.watch(sessionProvider).book;
  return (cards: await book.factCards(programId), sources: await book.factSources(programId));
});

/// A program's criteria, read again after every write (for the likely
/// questions on the Research stage).
final programCriteriaProvider = FutureProvider.family<List<Criterion>, String>((ref, programId) {
  ref.watch(revisionProvider);
  return ref.watch(sessionProvider).book.programCriteria(programId);
});
