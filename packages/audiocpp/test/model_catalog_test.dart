import 'dart:io';

import 'package:audiocpp/audiocpp.dart';
import 'package:flutter_test/flutter_test.dart';

/// Parses the real specs out of the submodule.
///
/// These are the exact documents the app ships, so a parser change that breaks
/// on real data fails here rather than at runtime.
ModelCatalog? _realCatalog() {
  final dir = Directory('../../third_party/audio.cpp/model_specs');
  if (!dir.existsSync()) {
    return null;
  }
  final sources = dir
      .listSync()
      .whereType<File>()
      .where((File f) => f.path.endsWith('.json'))
      .map((File f) => f.readAsStringSync());
  return ModelCatalog.parse(sources);
}

void main() {
  group('ModelPackage path handling', () {
    const source = DownloadSource(
      kind: DownloadKind.huggingFaceSnapshot,
      repo: 'audio-cpp/MiniMax-Music3-GGUF',
    );

    ModelPackage packageWith({String stripPrefix = '', String target = 'Target'}) {
      return ModelPackage(
        id: 'p',
        family: 'f',
        displayName: 'P',
        isDefault: true,
        format: 'gguf',
        precision: 'q4_0',
        targetDirectory: target,
        files: const [],
        stripPrefix: stripPrefix,
        download: source,
      );
    }

    test('joins the target directory when there is no prefix', () {
      expect(
        packageWith().localPathFor('config/language_model.json'),
        'Target/config/language_model.json',
      );
    });

    test('strips the declared prefix', () {
      // Several packages list files under a repo-level folder that must not be
      // repeated inside the target directory.
      expect(
        packageWith(stripPrefix: 'MuScriptor-Small-GGUF', target: 'MuScriptor-Small-GGUF')
            .localPathFor('MuScriptor-Small-GGUF/model.gguf'),
        'MuScriptor-Small-GGUF/model.gguf',
      );
    });

    test('tolerates a trailing slash on the prefix', () {
      expect(
        packageWith(stripPrefix: 'a/').localPathFor('a/b.gguf'),
        'Target/b.gguf',
      );
    });

    test('treats a "." prefix as no prefix', () {
      // vietneu_tts ships strip_prefix "." with top-level files. Upstream's own
      // installer rejects that package; we read the obvious intent instead.
      expect(
        packageWith(stripPrefix: '.').localPathFor('model.gguf'),
        'Target/model.gguf',
      );
    });

    test('rejects a file that does not carry the prefix', () {
      expect(
        () => packageWith(stripPrefix: 'a').localPathFor('b/c.gguf'),
        throwsA(isA<UnsafeModelPathException>()),
      );
    });

    test('rejects path traversal', () {
      // The specs are trusted, but a traversal must never silently write
      // outside the models root.
      expect(
        () => packageWith().localPathFor('../../etc/passwd'),
        throwsA(isA<UnsafeModelPathException>()),
      );
      expect(
        () => packageWith().localPathFor('/etc/passwd'),
        throwsA(isA<UnsafeModelPathException>()),
      );
    });

    test('builds the Hugging Face resolve URL', () {
      expect(
        source.urlFor('config/language_model.json').toString(),
        'https://huggingface.co/audio-cpp/MiniMax-Music3-GGUF/resolve/main/config/language_model.json',
      );
    });

    test('encodes spaces in filenames without escaping separators', () {
      expect(
        source.urlFor('a b/c d.gguf').toString(),
        'https://huggingface.co/audio-cpp/MiniMax-Music3-GGUF/resolve/main/a%20b/c%20d.gguf',
      );
    });
  });

  group('ModelOption', () {
    test('normalises defaults of every type to strings', () {
      // The engine takes all options as strings, so 20.0 must not reach it
      // as "20.0" when the docs say 20.
      ModelOption parse(Object? value) => ModelOption.fromJson(<String, Object?>{
            'name': 'x',
            'type': 'float',
            'description': '',
            'required': false,
            'default': value,
          });

      expect(parse(20.0).defaultValue, '20');
      expect(parse(1.7).defaultValue, '1.7');
      expect(parse(30).defaultValue, '30');
      expect(parse(true).defaultValue, 'true');
      expect(parse('q4').defaultValue, 'q4');
      expect(parse(null).defaultValue, isNull);
    });

    test('reads enum values and bounds', () {
      final option = ModelOption.fromJson(const <String, Object?>{
        'name': 'mode',
        'type': 'enum',
        'description': 'Mode',
        'required': true,
        'values': <String>['a', 'b'],
      });
      expect(option.type, ModelOptionType.enumeration);
      expect(option.values, <String>['a', 'b']);
      expect(option.required, isTrue);
      expect(option.hasFullRange, isFalse);
    });
  });

  group('real specs', () {
    final catalog = _realCatalog();
    final skip = catalog == null ? 'audio.cpp submodule not checked out' : null;

    test('parses every shipped spec', () {
      expect(catalog!.specs.length, greaterThanOrEqualTo(50));
    }, skip: skip);

    test('finds MiniMax Music 3 and its packages', () {
      final spec = catalog!.specForFamily('minimax_music3');

      expect(spec, isNotNull);
      expect(spec!.isMusicOrSfx, isTrue);
      expect(spec.category, ModelCategory.audioGeneration);
      expect(
        spec.packages.map((ModelPackage p) => p.id),
        containsAll(<String>['minimax_music3_q4_0', 'minimax_music3_q8_0']),
      );
      expect(spec.recommendedPackage?.id, 'minimax_music3_q4_0');
      expect(spec.recommendedPackage?.download.repo, 'audio-cpp/MiniMax-Music3-GGUF');
      expect(spec.recommendedPackage?.files, hasLength(13));
    }, skip: skip);

    test('exposes the required lyrics option', () {
      // The Create screen depends on this: MiniMax Music 3 cannot run
      // instrumental, and the spec is where we learn that.
      final lyrics =
          catalog!.specForFamily('minimax_music3')!.options.findRequest('lyrics');

      expect(lyrics, isNotNull);
      expect(lyrics!.required, isTrue);
      expect(lyrics.type, ModelOptionType.string);
    }, skip: skip);

    test('reads documented defaults for MiniMax Music 3', () {
      final options = catalog!.specForFamily('minimax_music3')!.options;

      expect(options.findRequest('duration_sec')?.defaultValue, '20');
      expect(options.findRequest('num_inference_steps')?.defaultValue, '30');
      expect(options.findRequest('guidance_scale')?.defaultValue, '1.7');
    }, skip: skip);

    test('music and SFX filter selects the generation families', () {
      final families = catalog!.musicAndSfx.map((ModelSpec s) => s.family).toSet();

      expect(
        families,
        containsAll(<String>['minimax_music3', 'stable_audio', 'ace_step']),
      );
      // ASR families must not leak into a music app's catalogue.
      expect(families, isNot(contains('qwen3_asr')));
      expect(families, isNot(contains('silero_vad')));
    }, skip: skip);

    test('Stable Audio offers a dedicated SFX package', () {
      final spec = catalog!.specForFamily('stable_audio')!;

      expect(spec.tasks, contains('sfx'));
      expect(
        spec.packages.map((ModelPackage p) => p.id),
        contains('stable_audio_3_small_sfx_q8_0'),
      );
    }, skip: skip);

    test('every fetchable package resolves safe local paths for all its files', () {
      // Guards the whole catalogue against a spec that would write outside the
      // models root, across every family, not just the ones we ship today.
      for (final spec in catalog!.specs) {
        for (final package in spec.fetchablePackages) {
          for (final file in package.files) {
            final local = package.localPathFor(file);
            expect(local, startsWith('${package.targetDirectory}/'));
            expect(local, isNot(contains('..')));
          }
        }
      }
    }, skip: skip);

    test('unsupported packages are excluded from fetchable', () {
      final unsupported = <ModelPackage>[
        for (final spec in catalog!.specs)
          for (final package in spec.packages)
            if (package.download.kind == DownloadKind.unsupported) package,
      ];

      expect(unsupported, isNotEmpty, reason: 'specs do declare unsupported packages');
      for (final package in unsupported) {
        expect(package.isFetchable, isFalse);
      }
    }, skip: skip);
  });
}
