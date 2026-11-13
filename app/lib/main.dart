import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

// ---------------------------------------------------------------------------
// Inicialização
// ---------------------------------------------------------------------------

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const CircuitoApp());
}

final FirebaseFirestore db = FirebaseFirestore.instance;
final FirebaseAnalytics analytics = FirebaseAnalytics.instance;
final Missao missao = Missao();

String get uidVisitante => FirebaseAuth.instance.currentUser!.uid;

class CircuitoApp extends StatelessWidget {
  const CircuitoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Circuito de Descobertas',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0B7A55)),
      ),
      home: const Bootstrap(),
    );
  }
}

/// Faz login anônimo do visitante e carrega o Remote Config antes de abrir a
/// tela inicial. Se algo falhar, mostra o erro na tela (ajuda a depurar no
/// celular).
class Bootstrap extends StatefulWidget {
  const Bootstrap({super.key});

  @override
  State<Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<Bootstrap> {
  late Future<void> _init = _iniciar();

  Future<void> _iniciar() async {
    final auth = FirebaseAuth.instance;
    if (auth.currentUser == null) {
      await auth.signInAnonymously();
    }
    await analytics.setAnalyticsCollectionEnabled(true);
    await missao.iniciar();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _init,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.hasError) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off, size: 56),
                    const SizedBox(height: 12),
                    const Text('Não foi possível conectar ao Firebase.',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text('${snap.error}', textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => setState(() => _init = _iniciar()),
                      child: const Text('Tentar novamente'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        return const HomePage();
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Missão surpresa (Remote Config com atualização em tempo real)
// ---------------------------------------------------------------------------

class Missao extends ChangeNotifier {
  final FirebaseRemoteConfig _rc = FirebaseRemoteConfig.instance;
  StreamSubscription<RemoteConfigUpdate>? _sub;

  bool ativa = false;
  List<String> estandes = const [];
  String titulo = 'Missão surpresa!';
  String mensagem = 'Visite os estandes destacados e faça o check-in.';

  Future<void> iniciar() async {
    if (_sub != null) return;
    await _rc.setConfigSettings(RemoteConfigSettings(
      fetchTimeout: const Duration(seconds: 15),
      minimumFetchInterval: const Duration(seconds: 30),
    ));
    // Padrão local: missão DESLIGADA.
    await _rc.setDefaults(const {
      'missao_ativa': false,
      'missao_estandes': '',
      'missao_titulo': 'Missão surpresa!',
      'missao_mensagem': 'Visite os estandes destacados e faça o check-in.',
    });
    _ler();
    try {
      await _rc.fetchAndActivate();
    } catch (_) {
      // Sem rede: continua com os padrões locais.
    }
    _ler();
    // Tempo real: quando a organização publica no console, o app recebe a
    // atualização, ativa e redesenha a tela sem reinstalar.
    _sub = _rc.onConfigUpdated.listen((_) async {
      await _rc.activate();
      _ler();
    }, onError: (_) {});
  }

  void _ler() {
    ativa = _rc.getBool('missao_ativa');
    estandes = _rc
        .getString('missao_estandes')
        .split(RegExp(r'[,;\s]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final t = _rc.getString('missao_titulo').trim();
    final m = _rc.getString('missao_mensagem').trim();
    if (t.isNotEmpty) titulo = t;
    if (m.isNotEmpty) mensagem = m;
    notifyListeners();
  }

  bool destaca(String estandeId) => ativa && estandes.contains(estandeId);
}

// ---------------------------------------------------------------------------
// Modelo
// ---------------------------------------------------------------------------

class Estande {
  final String id;
  final String nome;
  final String descricao;
  final String localizacao;

  Estande(this.id, Map<String, dynamic> d)
      : nome = (d['nome'] ?? 'Sem nome').toString(),
        descricao = (d['descricao'] ?? '').toString(),
        localizacao = (d['localizacao'] ?? '').toString();
}

Stream<List<Estande>> estandesAtivos() => db
    .collection('estandes')
    .where('ativo', isEqualTo: true)
    .snapshots()
    .map((s) {
      final lista = s.docs.map((d) => Estande(d.id, d.data())).toList();
      lista.sort((a, b) => a.nome.toLowerCase().compareTo(b.nome.toLowerCase()));
      return lista;
    });

Stream<Set<String>> meusCheckins() => db
    .collection('checkins')
    .where('visitanteId', isEqualTo: uidVisitante)
    .snapshots()
    .map((s) => s.docs.map((d) => (d.data()['estandeId'] ?? '').toString()).toSet());

// ---------------------------------------------------------------------------
// Tela inicial
// ---------------------------------------------------------------------------

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final Stream<List<Estande>> _estandes = estandesAtivos();
  late final Stream<Set<String>> _visitados = meusCheckins();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Circuito de Descobertas'),
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => fazerCheckin(context),
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text('Check-in'),
      ),
      body: StreamBuilder<List<Estande>>(
        stream: _estandes,
        builder: (context, snapE) {
          if (snapE.hasError) {
            return MensagemCentral(
                icone: Icons.error_outline, texto: 'Erro ao carregar estandes:\n${snapE.error}');
          }
          if (!snapE.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final estandes = snapE.data!;
          return StreamBuilder<Set<String>>(
            stream: _visitados,
            builder: (context, snapV) {
              final visitados = snapV.data ?? <String>{};
              return ListenableBuilder(
                listenable: missao,
                builder: (context, _) {
                  final destacados =
                      estandes.where((e) => missao.destaca(e.id)).toList();
                  final itens = <Widget>[
                    if (missao.ativa)
                      BannerMissao(destacados: destacados, visitados: visitados),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                      child: Text('Estandes (${estandes.length})',
                          style: Theme.of(context).textTheme.titleMedium),
                    ),
                    if (estandes.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(32),
                        child: Text('Nenhum estande ativo no momento.',
                            textAlign: TextAlign.center),
                      ),
                    ...estandes.map((e) => CartaoEstande(
                          estande: e,
                          destacado: missao.destaca(e.id),
                          visitado: visitados.contains(e.id),
                        )),
                    const SizedBox(height: 96),
                  ];
                  return ListView(children: itens);
                },
              );
            },
          );
        },
      ),
    );
  }
}

class BannerMissao extends StatelessWidget {
  final List<Estande> destacados;
  final Set<String> visitados;

  const BannerMissao({super.key, required this.destacados, required this.visitados});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final feitos = destacados.where((e) => visitados.contains(e.id)).length;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      color: cs.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.flag_circle, color: cs.onTertiaryContainer, size: 32),
              const SizedBox(width: 8),
              Expanded(
                child: Text(missao.titulo,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: cs.onTertiaryContainer, fontWeight: FontWeight.bold)),
              ),
            ]),
            const SizedBox(height: 8),
            Text(missao.mensagem, style: TextStyle(color: cs.onTertiaryContainer)),
            const SizedBox(height: 4),
            Text('${destacados.length} estande(s) participante(s) • $feitos visitado(s)',
                style: TextStyle(color: cs.onTertiaryContainer)),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () async {
                await analytics.logEvent(name: 'missao_aberta', parameters: {
                  'qtd_estandes': destacados.length,
                  'qtd_visitados': feitos,
                });
                if (!context.mounted) return;
                Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const MissaoPage()));
              },
              icon: const Icon(Icons.explore),
              label: const Text('Abrir missão'),
            ),
          ],
        ),
      ),
    );
  }
}

class CartaoEstande extends StatelessWidget {
  final Estande estande;
  final bool destacado;
  final bool visitado;

  const CartaoEstande(
      {super.key, required this.estande, required this.destacado, required this.visitado});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: destacado ? cs.secondaryContainer : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: destacado
            ? BorderSide(color: cs.tertiary, width: 2)
            : BorderSide(color: cs.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(estande.nome,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ),
              if (destacado)
                Chip(
                  avatar: const Icon(Icons.star, size: 18),
                  label: const Text('Missão'),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: cs.tertiaryContainer,
                ),
              if (visitado)
                const Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: Icon(Icons.check_circle, color: Colors.green),
                ),
            ]),
            if (estande.descricao.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(estande.descricao),
            ],
            if (estande.localizacao.isNotEmpty) ...[
              const SizedBox(height: 6),
              Row(children: [
                const Icon(Icons.place, size: 18),
                const SizedBox(width: 4),
                Expanded(child: Text(estande.localizacao)),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tela da missão
// ---------------------------------------------------------------------------

class MissaoPage extends StatefulWidget {
  const MissaoPage({super.key});

  @override
  State<MissaoPage> createState() => _MissaoPageState();
}

class _MissaoPageState extends State<MissaoPage> {
  late final Stream<List<Estande>> _estandes = estandesAtivos();
  late final Stream<Set<String>> _visitados = meusCheckins();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Missão surpresa')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => fazerCheckin(context),
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text('Check-in'),
      ),
      body: ListenableBuilder(
        listenable: missao,
        builder: (context, _) {
          if (!missao.ativa) {
            return const MensagemCentral(
                icone: Icons.flag_outlined,
                texto: 'A missão foi encerrada pela organização.\n'
                    'A lista de estandes e o check-in continuam disponíveis.');
          }
          return StreamBuilder<List<Estande>>(
            stream: _estandes,
            builder: (context, snapE) {
              if (!snapE.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final destacados =
                  snapE.data!.where((e) => missao.destaca(e.id)).toList();
              return StreamBuilder<Set<String>>(
                stream: _visitados,
                builder: (context, snapV) {
                  final visitados = snapV.data ?? <String>{};
                  final feitos =
                      destacados.where((e) => visitados.contains(e.id)).length;
                  final total = destacados.length;
                  return ListView(
                    padding: const EdgeInsets.only(bottom: 96),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(missao.titulo,
                                style: Theme.of(context).textTheme.headlineSmall),
                            const SizedBox(height: 6),
                            Text(missao.mensagem),
                            const SizedBox(height: 12),
                            LinearProgressIndicator(
                                value: total == 0 ? 0 : feitos / total, minHeight: 8),
                            const SizedBox(height: 6),
                            Text('$feitos de $total estandes visitados'),
                          ],
                        ),
                      ),
                      if (destacados.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('Nenhum estande participante ativo.',
                              textAlign: TextAlign.center),
                        ),
                      ...destacados.map((e) => CartaoEstande(
                            estande: e,
                            destacado: true,
                            visitado: visitados.contains(e.id),
                          )),
                      if (total > 0 && feitos == total)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('🎉 Parabéns! Você completou a missão!',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        ),
                    ],
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Check-in por QR code
// ---------------------------------------------------------------------------

const String prefixoQr = 'circuito:';

/// Aceita "circuito:<id>" (formato gerado pelo painel) ou o id puro.
String? extrairIdEstande(String bruto) {
  var s = bruto.trim();
  if (s.startsWith(prefixoQr)) s = s.substring(prefixoQr.length).trim();
  if (!RegExp(r'^[A-Za-z0-9_-]{3,100}$').hasMatch(s)) return null;
  return s;
}

Future<void> fazerCheckin(BuildContext context) async {
  final codigo = await Navigator.push<String>(
      context, MaterialPageRoute(builder: (_) => const ScannerPage()));
  if (codigo == null || !context.mounted) return;
  await registrarCheckin(context, codigo);
}

enum Resultado { sucesso, invalido, inativo, repetido, erro }

Future<void> registrarCheckin(BuildContext context, String codigo) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );

  Resultado res;
  String detalhe = '';
  try {
    final id = extrairIdEstande(codigo);
    if (id == null) {
      res = Resultado.invalido;
    } else {
      final est = await db.collection('estandes').doc(id).get();
      if (!est.exists) {
        res = Resultado.invalido;
      } else {
        final dados = est.data()!;
        final nome = (dados['nome'] ?? '').toString();
        detalhe = nome;
        if (dados['ativo'] != true) {
          res = Resultado.inativo;
        } else {
          // Chave composta visitante + estande evita duplicatas.
          final ref = db.collection('checkins').doc('${uidVisitante}_$id');
          final existente = await ref.get();
          if (existente.exists) {
            res = Resultado.repetido;
          } else {
            final destacado = missao.destaca(id);
            await ref.set({
              'visitanteId': uidVisitante,
              'estandeId': id,
              'estandeNome': nome,
              'missaoAtiva': missao.ativa,
              'criadoEm': FieldValue.serverTimestamp(),
            });
            await analytics.logEvent(name: 'checkin_concluido', parameters: {
              'estande_id': id,
              'estande_nome': nome.length > 90 ? nome.substring(0, 90) : nome,
              'missao_ativa': missao.ativa ? 'sim' : 'nao',
              'estande_destacado': destacado ? 'sim' : 'nao',
            });
            res = Resultado.sucesso;
          }
        }
      }
    }
  } on FirebaseException catch (e) {
    res = Resultado.erro;
    detalhe = e.message ?? e.code;
  } catch (e) {
    res = Resultado.erro;
    detalhe = e.toString();
  }

  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop(); // fecha o carregando

  final (IconData icone, Color cor, String titulo, String texto) = switch (res) {
    Resultado.sucesso => (
        Icons.check_circle,
        Colors.green,
        'Check-in confirmado!',
        'Sua visita ao estande "$detalhe" foi registrada.'
      ),
    Resultado.invalido => (
        Icons.qr_code_2,
        Colors.red,
        'QR inválido',
        'Este QR code não corresponde a nenhum estande do circuito.'
      ),
    Resultado.inativo => (
        Icons.block,
        Colors.orange,
        'Estande inativo',
        'O estande "$detalhe" não está ativo no momento. Tente mais tarde.'
      ),
    Resultado.repetido => (
        Icons.info,
        Colors.blue,
        'Visita já registrada',
        'Você já fez check-in no estande "$detalhe".'
      ),
    Resultado.erro => (
        Icons.error,
        Colors.red,
        'Erro ao registrar',
        'Não foi possível registrar o check-in.\n$detalhe'
      ),
  };

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(icone, color: cor, size: 56),
      title: Text(titulo),
      content: Text(texto, textAlign: TextAlign.center),
      actions: [
        FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
      ],
    ),
  );
}

class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  final MobileScannerController _controller =
      MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates);
  bool _lido = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _finalizar(String valor) {
    if (_lido) return;
    _lido = true;
    Navigator.pop(context, valor);
  }

  Future<void> _digitar() async {
    final ctrl = TextEditingController();
    final valor = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Digitar código do estande'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'ID do estande'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('Confirmar')),
        ],
      ),
    );
    if (valor != null && valor.trim().isNotEmpty) _finalizar(valor);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ler QR do estande'),
        actions: [
          IconButton(
            tooltip: 'Lanterna',
            icon: const Icon(Icons.flashlight_on),
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: (capture) {
              for (final b in capture.barcodes) {
                final v = b.rawValue;
                if (v != null && v.isNotEmpty) {
                  _finalizar(v);
                  return;
                }
              }
            },
          ),
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: Column(
              children: [
                const Text('Aponte a câmera para o QR code do estande',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        shadows: [Shadow(blurRadius: 4)])),
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  onPressed: _digitar,
                  icon: const Icon(Icons.keyboard),
                  label: const Text('Digitar código'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class MensagemCentral extends StatelessWidget {
  final IconData icone;
  final String texto;

  const MensagemCentral({super.key, required this.icone, required this.texto});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icone, size: 56),
          const SizedBox(height: 12),
          Text(texto, textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}
