import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

// =================================================================
// COULEURS DE LA MARQUE : modifier ici pour changer toute l'application
// =================================================================
const Color kRouge = Color(0xFFE81B23);  // rouge vif
const Color kOrange = Color(0xFFFF6D00); // orange vif

// Durée passée en arrière-plan après laquelle le code PIN est redemandé
const Duration kDelaiVerrouillage = Duration(minutes: 1);

// Connexion au serveur en ligne (Supabase).
// La clé "publishable" est faite pour être dans l'application : la sécurité repose
// sur les règles d'accès de la base de données.
// NE JAMAIS mettre ici une clé commençant par "sb_secret_" ni la clé "service_role".
const String kSupabaseUrl = 'https://oqzofqjerbzycsncrggc.supabase.co';
const String kSupabaseCle = 'sb_publishable_cbPHMfPP8adkdki8LvOWow_uQTJSKnT';

// L'application s'affiche tout de suite (écran de démarrage rouge) ; le chargement
// des données se fait pendant ce temps, dans _SalonAppState._demarrer()
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SalonApp());
}

// Permet d'afficher un message (ex : échec d'enregistrement) depuis n'importe où
final GlobalKey<ScaffoldMessengerState> _messengerKey =
    GlobalKey<ScaffoldMessengerState>();

// Permet de fermer les fenêtres ouvertes quand l'application se verrouille
final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

// =================================================================
// OUTILS D'AFFICHAGE
// =================================================================
String formaterMontant(int montant) {
  final chiffres = montant.abs().toString();
  final tampon = StringBuffer();
  for (var i = 0; i < chiffres.length; i++) {
    if (i > 0 && (chiffres.length - i) % 3 == 0) tampon.write('\u00A0');
    tampon.write(chiffres[i]);
  }
  return montant < 0 ? '-$tampon' : tampon.toString();
}

String formaterDate(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

String formaterHeure(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

// =================================================================
// JOURNAL DES OPERATIONS
// Chaque prestation et chaque dépense est une ligne du journal : elle a un
// identifiant unique, une date, un montant. Les totaux sont TOUJOURS calculés
// à partir de ces lignes, jamais stockés à part.
// =================================================================
enum TypeOperation { prestation, depense }

class Operation {
  final String id;
  final TypeOperation type;
  final DateTime date;
  final int montant; // en CDF, nombre entier
  final int coiffeur; // position du coiffeur (prestation), -1 pour une dépense
  final double note; // note du client (prestation), 0 pour une dépense
  final String explication; // motif (dépense), vide pour une prestation
  final DateTime? annuleeLe; // renseigné si l'opération a été annulée
  final String motifAnnulation; // pourquoi elle a été annulée

  const Operation({
    required this.id,
    required this.type,
    required this.date,
    required this.montant,
    required this.coiffeur,
    required this.note,
    required this.explication,
    this.annuleeLe,
    this.motifAnnulation = '',
  });

  bool get annulee => annuleeLe != null;

  // L'opération n'est JAMAIS effacée : elle reste dans le journal, marquée annulée
  Operation avecAnnulation(DateTime quand, String motif) {
    return Operation(
      id: id,
      type: type,
      date: date,
      montant: montant,
      coiffeur: coiffeur,
      note: note,
      explication: explication,
      annuleeLe: quand,
      motifAnnulation: motif,
    );
  }

  Map<String, dynamic> versJson() {
    final json = <String, dynamic>{
      'id': id,
      't': type == TypeOperation.prestation ? 'p' : 'd',
      'd': date.millisecondsSinceEpoch,
      'm': montant,
    };
    if (type == TypeOperation.prestation) {
      json['c'] = coiffeur;
      json['n'] = note;
    } else {
      json['e'] = explication;
    }
    if (annuleeLe != null) {
      json['a'] = annuleeLe!.millisecondsSinceEpoch;
      json['x'] = motifAnnulation;
    }
    return json;
  }

  // Retourne null si la ligne est incomplète ou incohérente
  static Operation? depuisJson(dynamic j) {
    final op = _depuisJsonBase(j);
    if (op == null || j is! Map) return op;
    final a = j['a'];
    if (a is int && a > 0 && a <= 4102444800000) {
      final x = j['x'];
      return op.avecAnnulation(
        DateTime.fromMillisecondsSinceEpoch(a),
        x is String ? x : '',
      );
    }
    return op;
  }

  static Operation? _depuisJsonBase(dynamic j) {
    if (j is! Map) return null;
    final id = j['id'];
    final t = j['t'];
    final d = j['d'];
    final m = j['m'];
    if (id is! String || id.isEmpty) return null;
    if (d is! int || d <= 0 || d > 4102444800000) return null; // avant l'an 2100
    if (m is! int || m <= 0 || m > SalonData.montantMax) return null;

    final date = DateTime.fromMillisecondsSinceEpoch(d);
    if (t == 'p') {
      final c = j['c'];
      final n = j['n'];
      if (c is! int || c < 0 || c >= SalonData.nbCoiffeurs) return null;
      if (n is! num || !n.isFinite || n < 1 || n > 5) return null;
      return Operation(
        id: id,
        type: TypeOperation.prestation,
        date: date,
        montant: m,
        coiffeur: c,
        note: n.toDouble(),
        explication: '',
      );
    }
    if (t == 'd') {
      final e = j['e'];
      if (e is! String) return null;
      return Operation(
        id: id,
        type: TypeOperation.depense,
        date: date,
        montant: m,
        coiffeur: -1,
        note: 0,
        explication: e,
      );
    }
    return null;
  }
}

// Résumé d'une journée, calculé à partir du journal
class BilanJour {
  final String cle; // format aaaa-mm-jj
  final DateTime date;
  int clients = 0;
  int entrees = 0;
  int sorties = 0;
  double sommeNotes = 0;
  int annulations = 0; // nombre d'opérations annulées ce jour-là
  final List<int> parCoiffeur = List<int>.filled(SalonData.nbCoiffeurs, 0);

  BilanJour(this.cle, this.date);

  int get solde => entrees - sorties;
  double? get cote => clients == 0 ? null : sommeNotes / clients;
}

// DONNEES EN MEMOIRE (STATE) + SAUVEGARDE SUR LE TELEPHONE
// ============================
class SalonData {
  // --- Paramètres de stockage ---
  static const int _versionDonnees = 2;
  static const String _cleStockage = 'coifhair_salon_data';
  static const String _cleSauvegardeCorrompue = 'coifhair_salon_data_corrompu';

  // Montant maximum accepté pour une opération (CDF) : évite les fautes de frappe
  static const int montantMax = 100000000;

  static const List<IconData> _icones = [
    Icons.brush,
    Icons.air,
    Icons.content_cut,
    Icons.face,
    Icons.cut,
    Icons.brush,
    Icons.air,
    Icons.face,
  ];

  static int get nbCoiffeurs => _icones.length;

  static String salonId = "";
  static String nomSalon = "SALON XXXXXX";
  static String commune = "";
  static String avenue = "";
  static String telephone = "";

  // Compte en ligne propriétaire des données de ce téléphone, rôle, état d'envoi
  static String compteId = "";
  static String role = ""; // 'proprietaire' ou 'gerant' (vide = pas encore défini)
  static bool salonEnLigne = false; // le salon existe-t-il sur le serveur ?
  static bool get estProprietaire => role == 'proprietaire';

  static List<Map<String, dynamic>> coiffeurs = _coiffeursParDefaut();

  // Journal de toutes les opérations
  static List<Operation> journal = [];

  // Reprise des données des anciennes versions (avant le journal)
  static int reportEntrees = 0;
  static int reportSorties = 0;
  static List<int> reportClients = List<int>.filled(_icones.length, 0);

  static bool get estConfigure => salonId.isNotEmpty;

  // Totaux de TOUTES les journées
  static int get totalEntrees =>
      reportEntrees +
      journal
          .where((o) => o.type == TypeOperation.prestation && !o.annulee)
          .fold<int>(0, (somme, o) => somme + o.montant);

  static int get totalSorties =>
      reportSorties +
      journal
          .where((o) => o.type == TypeOperation.depense && !o.annulee)
          .fold<int>(0, (somme, o) => somme + o.montant);

  static int get soldeCaisse => totalEntrees - totalSorties;

  // Pour la limite de la version gratuite : on compte TOUTES les prestations
  // enregistrées, même annulées (sinon annuler puis ressaisir contournerait la limite)
  static int get totalPrestationsEnregistrees =>
      reportClients.fold<int>(0, (somme, c) => somme + c) +
      journal.where((o) => o.type == TypeOperation.prestation).length;

  static List<Map<String, dynamic>> _coiffeursParDefaut() {
    return List<Map<String, dynamic>>.generate(
      _icones.length,
      (i) => {
        'nom': 'Coiffeur ${String.fromCharCode(65 + i)}',
        'icone': _icones[i],
      },
    );
  }

  // Identifiant unique et stable (salon ou opération) : il ne change JAMAIS.
  static String genererId([String prefixe = 'salon']) {
    final alea = Random.secure();
    final suffixe = List.generate(8, (_) => alea.nextInt(36).toRadixString(36)).join();
    return '${prefixe}_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}_$suffixe';
  }

  // Lit un montant saisi : retourne null s'il est vide, invalide, nul ou trop grand
  static int? lireMontant(String texte) {
    final montant = int.tryParse(texte.replaceAll(RegExp(r'\s'), ''));
    if (montant == null || montant <= 0 || montant > montantMax) return null;
    return montant;
  }

  // ---------------------------------------------------------------
  // JOURNAL : ajout d'opérations et calcul des bilans
  // ---------------------------------------------------------------
  static Future<void> _envoyerOperation(Operation op) async {
    final c = Compte._client;
    if (c == null || !salonEnLigne || salonId.isEmpty || !Compte.connecte) return;
    try {
      await c.from('operations').insert({
        'id': op.id,
        'salon_id': salonId,
        'type': op.type == TypeOperation.prestation ? 'prestation' : 'depense',
        'date_operation': op.date.toUtc().toIso8601String(),
        'montant': op.montant,
        'coiffeur_numero': op.type == TypeOperation.prestation ? op.coiffeur : null,
        'note': op.type == TypeOperation.prestation ? op.note : null,
        'explication': op.explication,
      });
    } catch (e) {
      _messengerKey.currentState?.showSnackBar(const SnackBar(
        content: Text('Opération conservée sur le téléphone, mais envoi en ligne échoué.'),
      ));
    }
  }

  static Future<void> _envoyerAnnulation(Operation op) async {
    final c = Compte._client;
    if (c == null || !salonEnLigne || salonId.isEmpty || !Compte.connecte) return;
    try {
      await c.from('operations').update({
        'annulee_le': op.annuleeLe!.toUtc().toIso8601String(),
        'motif_annulation': op.motifAnnulation,
      }).eq('id', op.id).eq('salon_id', salonId);
    } catch (_) {
      _messengerKey.currentState?.showSnackBar(const SnackBar(
        content: Text('Annulation conservée localement, mais synchronisation échouée.'),
      ));
    }
  }

  static Future<void> synchroniserJournal() async {
    final c = Compte._client;
    if (c == null || !salonEnLigne || salonId.isEmpty || !Compte.connecte) return;
    try {
      final rows = await c.from('operations').select().eq('salon_id', salonId);
      final idsServeur = rows.map((r) => r['id'] as String).toSet();
      for (final locale in journal.where((o) => !idsServeur.contains(o.id))) {
        try {
          await _envoyerOperation(locale);
          if (locale.annulee) await _envoyerAnnulation(locale);
        } catch (_) {}
      }
      final ids = journal.map((o) => o.id).toSet();
      for (final row in rows) {
        final op = Operation.depuisJson({
          'id': row['id'],
          't': row['type'] == 'prestation' ? 'p' : 'd',
          'd': DateTime.parse(row['date_operation']).toLocal().millisecondsSinceEpoch,
          'm': row['montant'],
          if (row['type'] == 'prestation') 'c': row['coiffeur_numero'],
          if (row['type'] == 'prestation') 'n': (row['note'] as num).toDouble(),
          if (row['type'] == 'depense') 'e': row['explication'],
          if (row['annulee_le'] != null) 'a': DateTime.parse(row['annulee_le']).toLocal().millisecondsSinceEpoch,
          if (row['motif_annulation'] != null) 'x': row['motif_annulation'],
        });
        if (op != null && ids.add(op.id)) journal.add(op);
      }
      await sauvegarder();
    } catch (_) {}
  }

  static Future<bool> renommerCoiffeurEnLigne(int index) async {
    if (index < 0 || index >= coiffeurs.length) return false;
    final c = Compte._client;
    if (c == null || !salonEnLigne || salonId.isEmpty || !Compte.connecte) return false;
    try {
      final rows = await c.from('coiffeurs').update({'nom': coiffeurs[index]['nom']})
          .eq('salon_id', salonId).eq('numero', index).select();
      return rows.isNotEmpty;
    } catch (_) { return false; }
  }

  static Future<void> _mettreEnFile(Operation op) async {
    await sauvegarder();
    unawaited(_envoyerOperation(op));
  }

  static Future<void> ajouterPrestation({
    required int coiffeur, required int montant, required double note,
  }) async {
    if (coiffeur < 0 || coiffeur >= nbCoiffeurs || montant <= 0 || montant > montantMax) return;
    final op = Operation(
      id: genererId('op'), type: TypeOperation.prestation, date: DateTime.now(),
      montant: montant, coiffeur: coiffeur, note: note.clamp(1.0, 5.0).toDouble(),
      explication: '',
    );
    journal.add(op);
    await _mettreEnFile(op);
  }

  static Future<void> ajouterDepense({
    required int montant, required String explication,
  }) async {
    if (montant <= 0 || montant > montantMax || explication.trim().isEmpty) return;
    final op = Operation(
      id: genererId('op'), type: TypeOperation.depense, date: DateTime.now(),
      montant: montant, coiffeur: -1, note: 0, explication: explication.trim(),
    );
    journal.add(op);
    await _mettreEnFile(op);
  }

  static bool peutEtreAnnulee(Operation op) =>
      !op.annulee && cleJour(op.date) == cleJour(DateTime.now());

  static Future<bool> annulerOperation(String id, String motif) async {
    final texte = motif.trim();
    if (texte.isEmpty) return false;
    final i = journal.indexWhere((o) => o.id == id);
    if (i < 0) return false;
    final op = journal[i];
    if (!peutEtreAnnulee(op)) return false;
    final annulee = op.avecAnnulation(DateTime.now(), texte);
    journal[i] = annulee;
    await sauvegarder();
    await _envoyerAnnulation(annulee);
    return true;
  }

  static String cleJour(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static DateTime? dateDeCle(String cle) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(cle)) return null;
    final p = cle.split('-');
    return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
  }

  static Map<String, BilanJour> _bilans() {
    final bilans = <String, BilanJour>{};
    for (final o in journal) {
      final cle = cleJour(o.date);
      final b = bilans.putIfAbsent(
        cle,
        () => BilanJour(cle, DateTime(o.date.year, o.date.month, o.date.day)),
      );
      if (o.annulee) {
        b.annulations++;
        continue;
      }
      if (o.type == TypeOperation.prestation) {
        b.clients++;
        b.entrees += o.montant;
        b.sommeNotes += o.note;
        b.parCoiffeur[o.coiffeur]++;
      } else {
        b.sorties += o.montant;
      }
    }
    return bilans;
  }

  static BilanJour bilanDuJour(DateTime jour) {
    return _bilans()[cleJour(jour)] ??
        BilanJour(cleJour(jour), DateTime(jour.year, jour.month, jour.day));
  }

  // Du plus récent au plus ancien
  static List<BilanJour> tousLesBilans() {
    final liste = _bilans().values.toList();
    liste.sort((a, b) => b.date.compareTo(a.date));
    return liste;
  }

  // Du plus récent au plus ancien
  static List<Operation> operationsDuJour(String cle) {
    final liste = journal.where((o) => cleJour(o.date) == cle).toList();
    liste.sort((a, b) => b.date.compareTo(a.date));
    return liste;
  }

  static bool get aUnReport =>
      reportEntrees > 0 ||
      reportSorties > 0 ||
      reportClients.any((c) => c > 0);

  // ---------------------------------------------------------------
  // CHARGEMENT (appelé une seule fois au démarrage, ne plante jamais)
  // ---------------------------------------------------------------
  static Future<void> charger() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final brut = prefs.getString(_cleStockage);
      if (brut == null) return; // premier lancement : valeurs par défaut

      try {
        final ignores = _appliquer(jsonDecode(brut));
        // Si certaines lignes étaient illisibles, on garde une copie complète
        if (ignores > 0) {
          await prefs.setString(_cleSauvegardeCorrompue, brut);
        }
      } catch (_) {
        // Données illisibles : on garde une copie pour récupération
        // puis l'application démarre avec des valeurs par défaut.
        await prefs.setString(_cleSauvegardeCorrompue, brut);
      }
    } catch (_) {
      // Stockage indisponible : l'application fonctionne quand même (en mémoire)
    }
  }

  static String _texte(dynamic v) => v is String ? v : '';

  static int _entierPositif(dynamic v) {
    if (v is num && v.isFinite && v > 0) return v.toInt();
    return 0;
  }

  // Vérifie TOUT avant d'appliquer : jamais de données à moitié chargées.
  // Retourne le nombre de lignes du journal ignorées car illisibles.
  static int _appliquer(dynamic data) {
    if (data is! Map) throw const FormatException('Format inattendu');
    var ignores = 0;
    final nb = _icones.length;

    // Noms des coiffeurs (+ nombre de clients des anciennes versions)
    final nouveauxCoiffeurs = _coiffeursParDefaut();
    final clientsAnciens = List<int>.filled(nb, 0);
    final brutCoiffeurs = data['coiffeurs'];
    if (brutCoiffeurs is List) {
      for (var i = 0; i < nb && i < brutCoiffeurs.length; i++) {
        final item = brutCoiffeurs[i];
        if (item is Map) {
          final nom = _texte(item['nom']).trim();
          if (nom.isNotEmpty) {
            nouveauxCoiffeurs[i]['nom'] = nom;
          }
          clientsAnciens[i] = _entierPositif(item['clients']);
        }
      }
    }

    // Report : totaux d'avant le journal (ou repris des anciennes versions)
    var nouvelEntrees = 0;
    var nouvelSorties = 0;
    var nouveauxClients = List<int>.filled(nb, 0);
    if (data['journal'] is List) {
      final report = data['report'];
      if (report is Map) {
        nouvelEntrees = _entierPositif(report['entrees']);
        nouvelSorties = _entierPositif(report['sorties']);
        final brutClients = report['clients'];
        if (brutClients is List) {
          for (var i = 0; i < nb && i < brutClients.length; i++) {
            nouveauxClients[i] = _entierPositif(brutClients[i]);
          }
        }
      }
    } else {
      // Données d'une ancienne version (V1.1) : on les garde comme "report"
      nouvelEntrees = _entierPositif(data['totalEntrees']);
      nouvelSorties = _entierPositif(data['totalSorties']);
      nouveauxClients = clientsAnciens;
    }

    // Journal
    final nouveauJournal = <Operation>[];
    final idsVus = <String>{};
    final brutJournal = data['journal'];
    if (brutJournal is List) {
      for (final item in brutJournal) {
        final op = Operation.depuisJson(item);
        if (op == null || !idsVus.add(op.id)) {
          ignores++;
          continue;
        }
        nouveauJournal.add(op);
      }
    }

    final nom = _texte(data['nomSalon']).trim();
    final roleLu = data['role'];
    final nouveauRole = (roleLu == 'proprietaire' || roleLu == 'gerant') ? roleLu as String : '';

    // Tout est valide : on applique d'un coup
    salonId = _texte(data['salonId']);
    nomSalon = nom.isEmpty ? nomSalon : nom;
    commune = _texte(data['commune']);
    avenue = _texte(data['avenue']);
    telephone = _texte(data['telephone']);
    compteId = _texte(data['compteId']);
    role = nouveauRole;
    salonEnLigne = data['salonEnLigne'] == true;
    coiffeurs = nouveauxCoiffeurs;
    reportEntrees = nouvelEntrees;
    reportSorties = nouvelSorties;
    reportClients = nouveauxClients;
    journal = nouveauJournal;
    return ignores;
  }

  // Adopte un salon existant en ligne (gérant qui rejoint, ou propriétaire sur un nouveau
  // téléphone). Refuse d'écraser un AUTRE salon déjà présent sur ce téléphone.
  static Future<bool> adopterSalon({
    required String id,
    required String nom,
    required String commune,
    required String avenue,
    required String telephone,
    required String role,
    required String compte,
    required List<Map<String, dynamic>> coiffeursEnLigne,
  }) async {
    if (estConfigure && salonId != id) return false;
    final premiereFois = !estConfigure;

    if (premiereFois) {
      final nouveauxCoiffeurs = _coiffeursParDefaut();
      for (final c in coiffeursEnLigne) {
        final numero = c['numero'];
        final nomC = c['nom'];
        if (numero is int &&
            numero >= 0 &&
            numero < nouveauxCoiffeurs.length &&
            nomC is String &&
            nomC.trim().isNotEmpty) {
          nouveauxCoiffeurs[numero]['nom'] = nomC.trim();
        }
      }
      coiffeurs = nouveauxCoiffeurs;
    }

    SalonData.salonId = id;
    SalonData.nomSalon = nom;
    SalonData.commune = commune;
    SalonData.avenue = avenue;
    SalonData.telephone = telephone;
    SalonData.role = role;
    SalonData.compteId = compte;
    SalonData.salonEnLigne = true;
    await sauvegarder();
    return true;
  }

  // ---------------------------------------------------------------
  // SAUVEGARDE (à appeler après chaque modification des données)
  // ---------------------------------------------------------------
  // Les sauvegardes sont mises en file d'attente : jamais deux écritures en même temps.
  static Future<void> _file = Future.value();

  static Future<void> sauvegarder() {
    _file = _file.then((_) => _ecrire());
    return _file;
  }

  static Map<String, dynamic> _versJson() {
    return {
      'version': _versionDonnees,
      'salonId': salonId,
      'nomSalon': nomSalon,
      'commune': commune,
      'avenue': avenue,
      'telephone': telephone,
      'compteId': compteId,
      'role': role,
      'salonEnLigne': salonEnLigne,
      'coiffeurs': coiffeurs.map((c) => {'nom': c['nom']}).toList(),
      'report': {
        'entrees': reportEntrees,
        'sorties': reportSorties,
        'clients': reportClients,
      },
      'journal': journal.map((o) => o.versJson()).toList(),
    };
  }

  // Tout est enregistré dans UNE seule clé : l'écriture est complète ou n'a pas lieu
  static Future<void> _ecrire() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ok = await prefs.setString(_cleStockage, jsonEncode(_versJson()));
      if (!ok) _signalerEchec();
    } catch (_) {
      _signalerEchec();
    }
  }

  static void _signalerEchec() {
    _messengerKey.currentState?.showSnackBar(
      const SnackBar(
        backgroundColor: Colors.red,
        duration: Duration(seconds: 6),
        content: Text(
          'Impossible d\'enregistrer les données sur le téléphone. '
          'Vérifiez l\'espace de stockage.',
        ),
      ),
    );
  }
}

// =================================================================
// SESSION : l'application est-elle déverrouillée ?
// =================================================================
class Session extends ChangeNotifier {
  Session._();
  static final Session instance = Session._();

  bool demarrageTermine = false;
  bool pinDefini = false;
  bool deverrouille = false;

  void terminerDemarrage() {
    demarrageTermine = true;
    notifyListeners();
  }

  // A appeler quand l'état du compte ou du salon change : la navigation se met à jour
  void rafraichir() {
    notifyListeners();
  }

  void definirPin() {
    pinDefini = true;
    deverrouille = true;
    notifyListeners();
  }

  void deverrouiller() {
    deverrouille = true;
    notifyListeners();
  }

  void verrouiller() {
    if (!pinDefini || !deverrouille) return;
    deverrouille = false;
    // Ferme les fenêtres ouvertes (saisie de prestation, de dépense...)
    _navigatorKey.currentState?.popUntil((route) => route is! PopupRoute);
    FocusManager.instance.primaryFocus?.unfocus();
    notifyListeners();
  }
}

// =================================================================
// CODE PIN : jamais stocké en clair, uniquement un hash salé protégé
// par le stockage sécurisé du téléphone (Keystore / Keychain)
// =================================================================
class ResultatPin {
  final bool ok;
  final int secondesVerrou; // > 0 si l'accès est temporairement bloqué
  final int tentativesRestantes;
  final bool erreurTechnique;

  const ResultatPin({
    required this.ok,
    this.secondesVerrou = 0,
    this.tentativesRestantes = 0,
    this.erreurTechnique = false,
  });
}

class PinService {
  static const FlutterSecureStorage _stockage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static const String _cleHash = 'coifhair_pin_hash'; // contient "sel:hash"
  static const String _cleEchecs = 'coifhair_pin_echecs';
  static const String _cleVerrou = 'coifhair_pin_verrou_jusqua';
  static const int _tentativesAvantVerrou = 5;
  static const int _iterations = 10000;

  // Au démarrage : un code PIN existe-t-il ?
  static Future<void> charger() async {
    try {
      final valeur = await _stockage.read(key: _cleHash);
      Session.instance.pinDefini = valeur != null && valeur.contains(':');
    } catch (_) {
      // Stockage sécurisé illisible : on demandera de créer un nouveau code
      Session.instance.pinDefini = false;
    }
  }

  // Nouveau salon : on repart d'un état propre
  static Future<void> reinitialiser() async {
    Session.instance.pinDefini = false;
    Session.instance.deverrouille = false;
    try {
      await _stockage.delete(key: _cleHash);
      await _stockage.delete(key: _cleEchecs);
      await _stockage.delete(key: _cleVerrou);
    } catch (_) {}
  }

  // Retourne un message d'erreur, ou null si le code est acceptable
  static String? erreurDeFormat(String pin) {
    if (!RegExp(r'^\d{4}$').hasMatch(pin)) {
      return 'Le code doit contenir exactement 4 chiffres';
    }
    const suites = [
      '0123', '1234', '2345', '3456', '4567', '5678', '6789',
      '3210', '4321', '5432', '6543', '7654', '8765', '9876',
    ];
    if (RegExp(r'^(\d)\1{3}$').hasMatch(pin) || suites.contains(pin)) {
      return 'Code trop facile à deviner (évitez 0000, 1234...)';
    }
    return null;
  }

  static String _nouveauSel() {
    final alea = Random.secure();
    return base64Encode(List<int>.generate(16, (_) => alea.nextInt(256)));
  }

  static String _hacher(String pin, String sel) {
    final selOctets = utf8.encode(sel);
    List<int> h = sha256.convert(utf8.encode('$sel:$pin')).bytes;
    for (var i = 0; i < _iterations; i++) {
      h = sha256.convert([...h, ...selOctets]).bytes;
    }
    return base64Encode(h);
  }

  // Comparaison en temps constant
  static bool _egal(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  // Enregistre un nouveau code : "sel:hash" dans UNE seule clé (tout ou rien)
  static Future<bool> definir(String pin) async {
    if (erreurDeFormat(pin) != null) return false;
    try {
      final sel = _nouveauSel();
      await _stockage.write(key: _cleHash, value: '$sel:${_hacher(pin, sel)}');
      await _stockage.write(key: _cleEchecs, value: '0');
      await _stockage.delete(key: _cleVerrou);
      return true;
    } catch (_) {
      return false;
    }
  }

  // Secondes restantes avant de pouvoir réessayer (0 = pas de blocage)
  static Future<int> secondesDeVerrou() async {
    try {
      final brut = await _stockage.read(key: _cleVerrou);
      final fin = int.tryParse(brut ?? '') ?? 0;
      final reste = ((fin - DateTime.now().millisecondsSinceEpoch) / 1000).ceil();
      if (reste <= 0) return 0;
      return min(reste, 900);
    } catch (_) {
      return 0;
    }
  }

  static Future<ResultatPin> verifier(String pin) async {
    try {
      final restant = await secondesDeVerrou();
      if (restant > 0) {
        return ResultatPin(ok: false, secondesVerrou: restant);
      }

      final stocke = await _stockage.read(key: _cleHash);
      final parties = (stocke ?? '').split(':');
      if (parties.length != 2) {
        return const ResultatPin(ok: false, erreurTechnique: true);
      }

      if (_egal(_hacher(pin, parties[0]), parties[1])) {
        await _stockage.write(key: _cleEchecs, value: '0');
        return const ResultatPin(ok: true);
      }

      // Mauvais code : après 5 erreurs, blocage de plus en plus long (30 s à 15 min)
      final echecs = (int.tryParse(await _stockage.read(key: _cleEchecs) ?? '') ?? 0) + 1;
      await _stockage.write(key: _cleEchecs, value: '$echecs');
      if (echecs % _tentativesAvantVerrou == 0) {
        final palier = min(echecs ~/ _tentativesAvantVerrou - 1, 5);
        final secondes = min(900, 30 * (1 << palier));
        final fin = DateTime.now().millisecondsSinceEpoch + secondes * 1000;
        await _stockage.write(key: _cleVerrou, value: '$fin');
        return ResultatPin(ok: false, secondesVerrou: secondes);
      }
      return ResultatPin(
        ok: false,
        tentativesRestantes: _tentativesAvantVerrou - echecs % _tentativesAvantVerrou,
      );
    } catch (_) {
      return const ResultatPin(ok: false, erreurTechnique: true);
    }
  }
}

// =================================================================
// COMPTE EN LIGNE (Supabase) : connexion, salon, équipe
// Les méthodes qui retournent un String? donnent null en cas de succès,
// sinon un message d'erreur en français prêt à être affiché.
// =================================================================
class MembreEquipe {
  final String userId;
  final String role;
  final String email;
  const MembreEquipe(this.userId, this.role, this.email);
}

class InvitationEquipe {
  final String id;
  final String email;
  const InvitationEquipe(this.id, this.email);
}

class DonneesEquipe {
  final List<MembreEquipe> membres;
  final List<InvitationEquipe> invitations;
  final String? erreur;
  const DonneesEquipe({
    this.membres = const [],
    this.invitations = const [],
    this.erreur,
  });
}

class Compte {
  static bool _pret = false;
  static bool _authEnCours = false;
  static String emailEnAttente = ''; // adresse en cours de confirmation
  static bool confirmationRequise = false;

  static const String _serviceIndisponible =
      'Service en ligne indisponible. Vérifiez votre connexion internet puis relancez l\'application.';

  static sb.SupabaseClient? get _client => _pret ? sb.Supabase.instance.client : null;

  // Appelée au démarrage. Ne bloque jamais l'application plus de 8 secondes :
  // si le réseau est lent, la connexion se fera dès qu'elle sera prête.
  static Future<void> initialiser() async {
    final travail = sb.Supabase.initialize(url: kSupabaseUrl, anonKey: kSupabaseCle).then((_) {
      _pret = true;
      sb.Supabase.instance.client.auth.onAuthStateChange.listen(
        (_) => Session.instance.rafraichir(),
        onError: (_) {},
      );
      Session.instance.rafraichir();
    });
    travail.catchError((_) {});
    try {
      await travail.timeout(const Duration(seconds: 8));
    } catch (_) {
      // Trop long ou impossible : l'application continue
    }
  }

  // "connecte" reste faux pendant une opération de connexion : l'application ne passe
  // à l'écran suivant qu'une fois toutes les vérifications terminées.
  static bool get connecte => !_authEnCours && _client?.auth.currentUser != null;
  static String get email => _client?.auth.currentUser?.email ?? '';
  static String get id => _client?.auth.currentUser?.id ?? '';

  static Future<String?> _auth(Future<String?> Function(sb.SupabaseClient c) action) async {
    final c = _client;
    if (c == null) return _serviceIndisponible;
    _authEnCours = true;
    try {
      return await action(c);
    } catch (e) {
      return _messageErreur(e);
    } finally {
      _authEnCours = false;
      Session.instance.rafraichir();
    }
  }

  static Future<String?> _simple(Future<String?> Function(sb.SupabaseClient c) action) async {
    final c = _client;
    if (c == null) return _serviceIndisponible;
    try {
      return await action(c);
    } catch (e) {
      return _messageErreur(e);
    } finally {
      Session.instance.rafraichir();
    }
  }

  static String _messageErreur(Object e) {
    if (e is sb.AuthException) {
      final m = e.message.toLowerCase();
      if (m.contains('not confirmed')) {
        confirmationRequise = true;
        return 'Adresse e-mail pas encore confirmée.';
      }
      if (m.contains('invalid login') || m.contains('invalid credentials')) {
        return 'E-mail ou mot de passe incorrect.';
      }
      if (m.contains('already registered') || m.contains('already exists')) {
        return 'Un compte existe déjà avec cette adresse. Connectez-vous.';
      }
      if (m.contains('rate limit') || m.contains('too many') || m.contains('after')) {
        return 'Trop de tentatives. Patientez quelques minutes puis réessayez.';
      }
      if (m.contains('expired') || (m.contains('invalid') && m.contains('token'))) {
        return 'Code incorrect ou expiré.';
      }
      if (m.contains('password')) {
        return 'Mot de passe refusé : choisissez-en un plus solide (8 caractères ou plus).';
      }
      return 'Connexion impossible. Vérifiez votre connexion internet et réessayez.';
    }
    if (e is sb.PostgrestException) {
      if (e.code == '23505') return 'Cet élément existe déjà.';
      if (e.code == '42501') return 'Action non autorisée pour votre rôle.';
      return 'Le serveur a refusé l\'opération. Réessayez plus tard.';
    }
    return 'Opération impossible. Vérifiez votre connexion internet et réessayez.';
  }

  // Vérifie que les données de ce téléphone appartiennent bien au compte connecté
  static Future<String?> _apresConnexion(sb.SupabaseClient c) async {
    final utilisateur = c.auth.currentUser;
    if (utilisateur == null) return 'Connexion impossible. Réessayez.';
    if (SalonData.compteId.isNotEmpty && SalonData.compteId != utilisateur.id) {
      await c.auth.signOut();
      return 'Ce téléphone contient déjà les données d\'un autre compte. '
          'Utilisez le compte d\'origine, ou effacez les données de l\'application.';
    }
    if (SalonData.compteId.isEmpty && SalonData.estConfigure) {
      // Données créées avant les comptes : elles sont rattachées à ce compte
      SalonData.compteId = utilisateur.id;
      unawaited(SalonData.sauvegarder());
    }
    if (SalonData.salonEnLigne) await SalonData.synchroniserJournal();
    return null;
  }

  // ---------------- Connexion / inscription ----------------

  static Future<String?> inscrire(String adresse, String motDePasse) {
    return _auth((c) async {
      final mail = adresse.trim().toLowerCase();
      final r = await c.auth.signUp(email: mail, password: motDePasse);
      // Adresse déjà inscrite : le serveur renvoie un utilisateur sans identité
      if (r.user != null && (r.user!.identities ?? []).isEmpty) {
        return 'Un compte existe déjà avec cette adresse. Connectez-vous.';
      }
      emailEnAttente = mail;
      if (r.session != null) return await _apresConnexion(c);
      return null; // en attente de la confirmation par code
    });
  }

  static Future<String?> confirmer(String code) {
    return _auth((c) async {
      final r = await c.auth.verifyOTP(
        email: emailEnAttente,
        token: code.trim(),
        type: sb.OtpType.signup,
      );
      if (r.session == null) return 'Code incorrect ou expiré.';
      return await _apresConnexion(c);
    });
  }

  static Future<String?> renvoyerCode() {
    return _simple((c) async {
      await c.auth.resend(type: sb.OtpType.signup, email: emailEnAttente);
      return null;
    });
  }

  static Future<String?> connecter(String adresse, String motDePasse) {
    confirmationRequise = false;
    return _auth((c) async {
      final mail = adresse.trim().toLowerCase();
      emailEnAttente = mail;
      final r = await c.auth.signInWithPassword(email: mail, password: motDePasse);
      if (r.session == null) return 'Connexion impossible. Réessayez.';
      return await _apresConnexion(c);
    });
  }

  // ---------------- Salon ----------------

  // Cherche le salon auquel ce compte a accès et l'adopte sur ce téléphone.
  // Retourne true si un salon est (ou était déjà) présent.
  static Future<bool> _chargerSalon(sb.SupabaseClient c) async {
    if (SalonData.estConfigure) return true;
    final salons = await c
        .from('salons')
        .select('id, nom, commune, avenue, telephone')
        .order('cree_le')
        .limit(1);
    if (salons.isEmpty) return false;
    final s = salons.first;
    final salonId = s['id'] as String;
    final membre = await c
        .from('membres')
        .select('role')
        .eq('salon_id', salonId)
        .eq('user_id', id)
        .maybeSingle();
    final roleLu = membre?['role'];
    if (roleLu != 'proprietaire' && roleLu != 'gerant') return false;
    final coiffeursEnLigne =
        await c.from('coiffeurs').select('numero, nom').eq('salon_id', salonId);
    // Nouveau téléphone pour ce salon : on repart d'un état propre pour le code PIN
    await PinService.reinitialiser();
    final adopte = await SalonData.adopterSalon(
      id: salonId,
      nom: s['nom'] as String,
      commune: (s['commune'] ?? '') as String,
      avenue: (s['avenue'] ?? '') as String,
      telephone: (s['telephone'] ?? '') as String,
      role: roleLu as String,
      compte: id,
      coiffeursEnLigne: coiffeursEnLigne,
    );
    if (adopte) await SalonData.synchroniserJournal();
    return adopte;
  }

  // Nouveau téléphone, ou création interrompue : on retrouve le salon existant
  static Future<bool> recupererSalonExistant() async {
    final c = _client;
    if (c == null) return false;
    try {
      final trouve = await _chargerSalon(c);
      Session.instance.rafraichir();
      return trouve;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> creerSalon({
    required String nom,
    required String commune,
    required String avenue,
    required String telephone,
  }) {
    return _simple((c) async {
      final nouvelId = SalonData.genererId();
      // Téléphone sans salon : on efface tout ancien code PIN resté sur l'appareil
      await PinService.reinitialiser();
      try {
        await c.from('salons').insert({
          'id': nouvelId,
          'nom': nom,
          'commune': commune,
          'avenue': avenue,
          'telephone': telephone,
        });
      } on sb.PostgrestException catch (e) {
        if (e.code == '23505') return 'Identifiant déjà utilisé, réessayez.';
        rethrow;
      }
      final ok = await SalonData.adopterSalon(
        id: nouvelId,
        nom: nom,
        commune: commune,
        avenue: avenue,
        telephone: telephone,
        role: 'proprietaire',
        compte: id,
        coiffeursEnLigne: const <Map<String, dynamic>>[],
      );
      if (!ok) return 'Ce téléphone contient déjà un autre salon.';
      return null;
    });
  }

  // Salon créé avant les comptes (version 1.2) : on l'enregistre en ligne
  static Future<String?> envoyerSalonExistant() {
    return _simple((c) async {
      if (!SalonData.estConfigure) return 'Aucun salon à envoyer.';
      var roleFinal = 'proprietaire';
      try {
        await c.from('salons').insert({
          'id': SalonData.salonId,
          'nom': SalonData.nomSalon,
          'commune': SalonData.commune,
          'avenue': SalonData.avenue,
          'telephone': SalonData.telephone,
        });
      } on sb.PostgrestException catch (e) {
        if (e.code != '23505') rethrow;
        // Déjà envoyé (ex. coupure avant la fin) : on vérifie qu'il est bien à nous
        final existant = await c
            .from('membres')
            .select('role')
            .eq('salon_id', SalonData.salonId)
            .eq('user_id', id)
            .maybeSingle();
        final r = existant?['role'];
        if (r != 'proprietaire' && r != 'gerant') {
          return 'Cet identifiant de salon est déjà utilisé par un autre compte.';
        }
        roleFinal = r as String;
      }
      // Les noms de coiffeurs déjà personnalisés sont envoyés aussi (sans bloquer)
      for (var i = 0; i < SalonData.coiffeurs.length; i++) {
        try {
          await c
              .from('coiffeurs')
              .update({'nom': SalonData.coiffeurs[i]['nom']})
              .eq('salon_id', SalonData.salonId)
              .eq('numero', i);
        } catch (_) {}
      }
      SalonData.role = roleFinal;
      SalonData.compteId = id;
      SalonData.salonEnLigne = true;
      await SalonData.sauvegarder();
      return null;
    });
  }

  static Future<String?> mettreAJourSalon() {
    return _simple((c) async {
      final lignes = await c
          .from('salons')
          .update({
            'nom': SalonData.nomSalon,
            'commune': SalonData.commune,
            'avenue': SalonData.avenue,
            'telephone': SalonData.telephone,
          })
          .eq('id', SalonData.salonId)
          .select();
      if (lignes.isEmpty) return 'Mise à jour refusée par le serveur.';
      return null;
    });
  }

  // Le gérant rejoint le salon qui l'a invité
  static Future<String?> rejoindreSalon() {
    return _simple((c) async {
      await c.rpc('accepter_invitations');
      final trouve = await _chargerSalon(c);
      if (!trouve) return 'Aucune invitation trouvée pour $email.';
      return null;
    });
  }

  // ---------------- Équipe (propriétaire) ----------------

  static Future<DonneesEquipe> chargerEquipe() async {
    final c = _client;
    if (c == null) return const DonneesEquipe(erreur: _serviceIndisponible);
    try {
      final m = await c
          .from('membres')
          .select('user_id, role, email')
          .eq('salon_id', SalonData.salonId);
      final i = await c
          .from('invitations')
          .select('id, email')
          .eq('salon_id', SalonData.salonId)
          .order('cree_le');
      return DonneesEquipe(
        membres: m
            .map((x) => MembreEquipe(
                  x['user_id'] as String,
                  x['role'] as String,
                  (x['email'] ?? '') as String,
                ))
            .toList(),
        invitations: i
            .map((x) => InvitationEquipe(x['id'] as String, x['email'] as String))
            .toList(),
      );
    } catch (e) {
      return DonneesEquipe(erreur: _messageErreur(e));
    }
  }

  static Future<String?> inviterGerant(String adresse) {
    return _simple((c) async {
      try {
        await c.from('invitations').insert({
          'salon_id': SalonData.salonId,
          'email': adresse.trim().toLowerCase(),
          'role': 'gerant',
        });
      } on sb.PostgrestException catch (e) {
        if (e.code == '23505') return 'Cette adresse est déjà invitée.';
        rethrow;
      }
      return null;
    });
  }

  static Future<String?> annulerInvitation(String invitationId) {
    return _simple((c) async {
      final lignes = await c.from('invitations').delete().eq('id', invitationId).select();
      if (lignes.isEmpty) return 'Suppression refusée par le serveur.';
      return null;
    });
  }

  static Future<String?> retirerMembre(String userId) {
    return _simple((c) async {
      final lignes = await c
          .from('membres')
          .delete()
          .eq('salon_id', SalonData.salonId)
          .eq('user_id', userId)
          .select();
      if (lignes.isEmpty) return 'Suppression refusée par le serveur.';
      return null;
    });
  }
}

// =================================================================
// VALIDATION DES CHAMPS (utilisée par la connexion ET le profil)
// =================================================================
class Validateurs {
  static String? obligatoire(String? valeur, String message) {
    if ((valeur ?? '').trim().isEmpty) return message;
    return null;
  }

  static String? email(String? valeur) {
    final texte = (valeur ?? '').trim();
    if (texte.length > 254 || !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(texte)) {
      return 'Entrez une adresse e-mail valide';
    }
    return null;
  }

  static String? motDePasse(String? valeur) {
    final texte = valeur ?? '';
    if (texte.length < 8) return 'Au moins 8 caractères';
    if (texte.length > 72) return 'Maximum 72 caractères';
    return null;
  }

  static String normaliserTelephone(String valeur) {
    return valeur.replaceAll(RegExp(r'[\s\-.]'), '');
  }

  static String? telephone(String? valeur) {
    final numero = normaliserTelephone(valeur ?? '');
    if (!RegExp(r'^\+?\d{9,15}$').hasMatch(numero)) {
      return 'Entrez un numéro valide (ex : 0812345678)';
    }
    return null;
  }
}

// Écrans accessibles selon l'étape où se trouve l'utilisateur
const List<String> _ecransCompte = [
  '/bienvenue',
  '/connexion',
  '/inscription',
  '/confirmation',
];
const List<String> _ecransSalon = ['/choix-role', '/creer-salon', '/rejoindre'];
const List<String> _ecransAvantTableau = [
  '/demarrage',
  '/bienvenue',
  '/connexion',
  '/inscription',
  '/confirmation',
  '/choix-role',
  '/creer-salon',
  '/rejoindre',
  '/envoi-salon',
  '/creer-pin',
  '/pin',
];

// Configuration du routeur avec les différents écrans
final GoRouter _router = GoRouter(
  navigatorKey: _navigatorKey,
  initialLocation: '/demarrage',
  refreshListenable: Session.instance,
  // Sécurité de navigation, dans cet ordre :
  // 0. chargement en cours          -> écran de démarrage
  // 1. pas de compte connecté       -> bienvenue / connexion / inscription
  // 2. pas de salon sur ce téléphone-> choix du rôle, création ou invitation
  // 3. salon pas encore en ligne    -> envoi du salon (anciennes versions)
  // 4. pas de code PIN              -> création du code PIN
  // 5. application verrouillée      -> saisie du code PIN
  // 6. sinon                        -> accès libre
  redirect: (context, state) {
    final lieu = state.matchedLocation;
    final session = Session.instance;

    if (!session.demarrageTermine) return lieu == '/demarrage' ? null : '/demarrage';
    if (!Compte.connecte) return _ecransCompte.contains(lieu) ? null : '/bienvenue';
    if (!SalonData.estConfigure) return _ecransSalon.contains(lieu) ? null : '/choix-role';
    if (!SalonData.salonEnLigne) return lieu == '/envoi-salon' ? null : '/envoi-salon';
    if (!session.pinDefini) return lieu == '/creer-pin' ? null : '/creer-pin';
    if (!session.deverrouille) return lieu == '/pin' ? null : '/pin';
    if (_ecransAvantTableau.contains(lieu)) return '/dashboard';
    if (lieu == '/equipe' && !SalonData.estProprietaire) return '/profil';
    return null;
  },
  routes: [
    GoRoute(path: '/demarrage', builder: (context, state) => const SplashScreen()),
    GoRoute(path: '/bienvenue', builder: (context, state) => const BienvenueScreen()),
    GoRoute(path: '/connexion', builder: (context, state) => const ConnexionScreen()),
    GoRoute(path: '/inscription', builder: (context, state) => const InscriptionScreen()),
    GoRoute(path: '/confirmation', builder: (context, state) => const ConfirmationScreen()),
    GoRoute(path: '/choix-role', builder: (context, state) => const ChoixRoleScreen()),
    GoRoute(path: '/creer-salon', builder: (context, state) => const CreerSalonScreen()),
    GoRoute(path: '/rejoindre', builder: (context, state) => const RejoindreScreen()),
    GoRoute(path: '/envoi-salon', builder: (context, state) => const EnvoiSalonScreen()),
    // Code PIN
    GoRoute(path: '/creer-pin', builder: (context, state) => const CreerPinScreen()),
    GoRoute(path: '/pin', builder: (context, state) => const PinScreen()),
    // Tableau de bord
    GoRoute(path: '/dashboard', builder: (context, state) => const DashboardScreen()),
    // Historique et détail d'une journée
    GoRoute(path: '/history', builder: (context, state) => const HistoryScreen()),
    GoRoute(
      path: '/history/:jour',
      builder: (context, state) => JourScreen(cle: state.pathParameters['jour'] ?? ''),
    ),
    // Caisse
    GoRoute(path: '/caisse', builder: (context, state) => const CaisseScreen()),
    // Profil du salon et équipe
    GoRoute(path: '/profil', builder: (context, state) => const ProfilScreen()),
    GoRoute(path: '/equipe', builder: (context, state) => const EquipeScreen()),
  ],
);

class SalonApp extends StatefulWidget {
  const SalonApp({super.key});

  @override
  State<SalonApp> createState() => _SalonAppState();
}

class _SalonAppState extends State<SalonApp> with WidgetsBindingObserver {
  DateTime? _miseEnArriere;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _demarrer();
  }

  // Chargement des données pendant que l'écran de démarrage est affiché (2 s minimum)
  Future<void> _demarrer() async {
    final debut = DateTime.now();
    try {
      await SalonData.charger();
      await PinService.charger();
      await Compte.initialiser();
    } catch (_) {
      // Chaque étape gère ses propres erreurs ; on ne bloque jamais le démarrage
    }
    final ecoule = DateTime.now().difference(debut);
    const minimum = Duration(milliseconds: 2200);
    if (ecoule < minimum) await Future.delayed(minimum - ecoule);
    Session.instance.terminerDemarrage();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Verrouille l'application si elle est restée trop longtemps en arrière-plan
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _miseEnArriere = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final debut = _miseEnArriere;
      _miseEnArriere = null;
      if (debut == null) return;
      final ecoule = DateTime.now().difference(debut);
      if (ecoule.isNegative || ecoule >= kDelaiVerrouillage) {
        Session.instance.verrouiller();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Coif-Hair',
      theme: ThemeData(
        useMaterial3: true,
        primarySwatch: Colors.red,
      ),
      scaffoldMessengerKey: _messengerKey,
      routerConfig: _router,
      debugShowCheckedModeBanner: false,
    );
  }
}

// =================================================================
// ELEMENTS VISUELS COMMUNS (couleurs de la marque)
// =================================================================
InputDecoration decorationChamp(String label, IconData icone, {Widget? suffixe}) {
  return InputDecoration(
    labelText: label,
    prefixIcon: Icon(icone, color: kOrange),
    suffixIcon: suffixe,
    filled: true,
    fillColor: const Color(0xFFFFF4EC),
    labelStyle: const TextStyle(color: Colors.black54),
    floatingLabelStyle: const TextStyle(color: kRouge, fontWeight: FontWeight.bold),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: Color(0xFFFFB27A), width: 1.2),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: const BorderSide(color: kRouge, width: 2),
    ),
    disabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: Colors.grey.shade300),
    ),
  );
}

ButtonStyle styleBoutonPrincipal() {
  return ElevatedButton.styleFrom(
    backgroundColor: kRouge,
    foregroundColor: Colors.white,
    minimumSize: const Size.fromHeight(54),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
  );
}

ButtonStyle styleBoutonSecondaire() {
  return OutlinedButton.styleFrom(
    foregroundColor: kRouge,
    side: const BorderSide(color: kOrange, width: 1.5),
    minimumSize: const Size.fromHeight(54),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
  );
}

// Petit cercle de chargement affiché dans un bouton
class ChargementBouton extends StatelessWidget {
  const ChargementBouton({super.key});

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 22,
      width: 22,
      child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
    );
  }
}

// Message d'erreur (ne s'affiche que s'il y a un message)
class BandeauErreur extends StatelessWidget {
  final String? message;
  const BandeauErreur(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    if (message == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFDECEC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kRouge.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: kRouge, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message!, style: const TextStyle(color: Color(0xFF8A1118))),
          ),
        ],
      ),
    );
  }
}

// Message d'information (ne s'affiche que s'il y a un message)
class BandeauInfo extends StatelessWidget {
  final String? message;
  const BandeauInfo(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    if (message == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4EC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kOrange.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, color: kOrange, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(message!)),
        ],
      ),
    );
  }
}

// Page type des écrans de compte : bandeau rouge arrondi + contenu défilant
class PageAuth extends StatelessWidget {
  final String titre;
  final String? sousTitre;
  final String? routeRetour;
  final Widget child;

  const PageAuth({
    super.key,
    required this.titre,
    required this.child,
    this.sousTitre,
    this.routeRetour,
  });

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: routeRetour == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && routeRetour != null) context.go(routeRetour!);
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        body: Column(
          children: [
            Container(
              width: double.infinity,
              padding: EdgeInsets.fromLTRB(
                20,
                MediaQuery.of(context).padding.top + 14,
                20,
                26,
              ),
              decoration: const BoxDecoration(
                color: kRouge,
                borderRadius: BorderRadius.vertical(bottom: Radius.circular(32)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (routeRetour != null)
                    IconButton(
                      padding: EdgeInsets.zero,
                      alignment: Alignment.centerLeft,
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => context.go(routeRetour!),
                    ),
                  const Text(
                    'Coif-Hair',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    titre,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (sousTitre != null) ...[
                    const SizedBox(height: 4),
                    Text(sousTitre!, style: const TextStyle(color: Colors.white70, fontSize: 14)),
                  ],
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Champ mot de passe avec bouton "afficher / masquer"
class ChampMotDePasse extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final String? Function(String?)? validator;
  final TextInputAction action;
  final ValueChanged<String>? onSubmitted;

  const ChampMotDePasse({
    super.key,
    required this.controller,
    required this.label,
    this.validator,
    this.action = TextInputAction.next,
    this.onSubmitted,
  });

  @override
  State<ChampMotDePasse> createState() => _ChampMotDePasseState();
}

class _ChampMotDePasseState extends State<ChampMotDePasse> {
  bool _masque = true;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      obscureText: _masque,
      enableSuggestions: false,
      autocorrect: false,
      textInputAction: widget.action,
      onFieldSubmitted: widget.onSubmitted,
      validator: widget.validator,
      inputFormatters: [LengthLimitingTextInputFormatter(72)],
      decoration: decorationChamp(
        widget.label,
        Icons.lock_outline,
        suffixe: IconButton(
          icon: Icon(
            _masque ? Icons.visibility_outlined : Icons.visibility_off_outlined,
            color: Colors.grey,
          ),
          onPressed: () => setState(() => _masque = !_masque),
        ),
      ),
    );
  }
}

// =================================================================
// CHAMPS DU SALON (partagés entre la création du salon et le profil)
// =================================================================
class ChampsSalon extends StatelessWidget {
  final TextEditingController nomSalon;
  final TextEditingController commune;
  final TextEditingController avenue;
  final TextEditingController telephone;
  final bool enabled;

  const ChampsSalon({
    super.key,
    required this.nomSalon,
    required this.commune,
    required this.avenue,
    required this.telephone,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Nom du Salon
        TextFormField(
          controller: nomSalon,
          enabled: enabled,
          textInputAction: TextInputAction.next,
          inputFormatters: [LengthLimitingTextInputFormatter(40)],
          decoration: decorationChamp('Nom du Salon', Icons.storefront_outlined),
          validator: (value) => Validateurs.obligatoire(value, 'Entrez le nom du salon'),
        ),
        const SizedBox(height: 15),

        // Commune
        TextFormField(
          controller: commune,
          enabled: enabled,
          textInputAction: TextInputAction.next,
          inputFormatters: [LengthLimitingTextInputFormatter(40)],
          decoration: decorationChamp('Adresse ou Commune (ex: Gombe)', Icons.location_city_outlined),
          validator: (value) => Validateurs.obligatoire(value, 'Entrez la commune'),
        ),
        const SizedBox(height: 15),

        // Avenue
        TextFormField(
          controller: avenue,
          enabled: enabled,
          textInputAction: TextInputAction.next,
          inputFormatters: [LengthLimitingTextInputFormatter(60)],
          decoration: decorationChamp('Avenue', Icons.place_outlined),
          validator: (value) => Validateurs.obligatoire(value, 'Entrez le nom de l\'avenue'),
        ),
        const SizedBox(height: 15),

        // Numéro de téléphone du propriétaire
        TextFormField(
          controller: telephone,
          enabled: enabled,
          keyboardType: TextInputType.phone,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9+\s\-]')),
            LengthLimitingTextInputFormatter(20),
          ],
          decoration: decorationChamp('Téléphone du Propriétaire / Gérant', Icons.phone_outlined),
          validator: Validateurs.telephone,
        ),
      ],
    );
  }
}

// Champ de saisie d'un code PIN (4 chiffres, masqué)
class ChampPin extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final ValueChanged<String>? onChanged;
  final bool enabled;
  final bool autofocus;

  const ChampPin({
    super.key,
    required this.controller,
    required this.label,
    this.onChanged,
    this.enabled = true,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      autofocus: autofocus,
      obscureText: true,
      enableSuggestions: false,
      autocorrect: false,
      keyboardType: TextInputType.number,
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 24, letterSpacing: 10),
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(4),
      ],
      onChanged: onChanged,
      decoration: decorationChamp(label, Icons.lock_outline),
    );
  }
}

// =================================================================
// ECRAN DE DEMARRAGE (rouge) : affiché pendant le chargement des données
// =================================================================
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kRouge,
      body: SafeArea(
        child: Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: 1),
            duration: const Duration(milliseconds: 900),
            builder: (context, valeur, enfant) => Opacity(opacity: valeur, child: enfant),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Coif-Hair',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 44,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                  SizedBox(height: 10),
                  Text(
                    "l'outil pour la gestion de votre salon",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white, fontSize: 17),
                  ),
                  SizedBox(height: 40),
                  SizedBox(
                    width: 30,
                    height: 30,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// =================================================================
// COMPTE : bienvenue, inscription, confirmation, connexion
// =================================================================
class BienvenueScreen extends StatelessWidget {
  const BienvenueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return PageAuth(
      titre: 'Bienvenue',
      sousTitre: 'L\'outil pour la gestion de votre salon',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          const Text(
            'Connectez-vous ou créez un compte pour commencer.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.black54, fontSize: 15),
          ),
          const SizedBox(height: 28),
          ElevatedButton(
            style: styleBoutonPrincipal(),
            onPressed: () => context.go('/connexion'),
            child: const Text('Se connecter'),
          ),
          const SizedBox(height: 14),
          OutlinedButton(
            style: styleBoutonSecondaire(),
            onPressed: () => context.go('/inscription'),
            child: const Text('Créer un compte'),
          ),
          const SizedBox(height: 26),
          const BandeauInfo(
            'Le propriétaire du salon crée un compte, puis invite son gérant par e-mail.',
          ),
        ],
      ),
    );
  }
}

class InscriptionScreen extends StatefulWidget {
  const InscriptionScreen({super.key});

  @override
  State<InscriptionScreen> createState() => _InscriptionScreenState();
}

class _InscriptionScreenState extends State<InscriptionScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _mdp = TextEditingController();
  final TextEditingController _confirmation = TextEditingController();
  bool _enCours = false;
  String? _erreur;

  Future<void> _valider() async {
    if (_enCours || !_formKey.currentState!.validate()) return;
    setState(() {
      _enCours = true;
      _erreur = null;
    });
    final erreur = await Compte.inscrire(_email.text, _mdp.text);
    if (!mounted) return;
    setState(() {
      _enCours = false;
      _erreur = erreur;
    });
    // Sans erreur : si le serveur attend une confirmation, on demande le code
    if (erreur == null && !Compte.connecte) context.go('/confirmation');
  }

  @override
  void dispose() {
    _email.dispose();
    _mdp.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PageAuth(
      titre: 'Créer un compte',
      sousTitre: 'Une adresse e-mail et un mot de passe suffisent.',
      routeRetour: '/bienvenue',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            BandeauErreur(_erreur),
            TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              textInputAction: TextInputAction.next,
              decoration: decorationChamp('Adresse e-mail', Icons.mail_outline),
              validator: Validateurs.email,
            ),
            const SizedBox(height: 14),
            ChampMotDePasse(
              controller: _mdp,
              label: 'Mot de passe (8 caractères minimum)',
              validator: Validateurs.motDePasse,
            ),
            const SizedBox(height: 14),
            ChampMotDePasse(
              controller: _confirmation,
              label: 'Confirmer le mot de passe',
              action: TextInputAction.done,
              onSubmitted: (_) => _valider(),
              validator: (v) => v != _mdp.text ? 'Les deux mots de passe sont différents' : null,
            ),
            const SizedBox(height: 22),
            ElevatedButton(
              style: styleBoutonPrincipal(),
              onPressed: _enCours ? null : _valider,
              child: _enCours ? const ChargementBouton() : const Text('Créer mon compte'),
            ),
            const SizedBox(height: 14),
            TextButton(
              onPressed: () => context.go('/connexion'),
              child: const Text(
                'J\'ai déjà un compte : me connecter',
                style: TextStyle(color: kOrange, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ConfirmationScreen extends StatefulWidget {
  const ConfirmationScreen({super.key});

  @override
  State<ConfirmationScreen> createState() => _ConfirmationScreenState();
}

class _ConfirmationScreenState extends State<ConfirmationScreen> {
  final TextEditingController _code = TextEditingController();
  Timer? _minuteur;
  int _attente = 0; // secondes avant de pouvoir redemander un code
  bool _enCours = false;
  String? _erreur;
  String? _info;

  @override
  void initState() {
    super.initState();
    if (Compte.emailEnAttente.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.go('/connexion');
      });
    }
    _attente = 30; // un code vient d'être envoyé
    _lancerMinuteur();
  }

  void _demarrerAttente(int secondes) {
    setState(() => _attente = secondes);
    _lancerMinuteur();
  }

  void _lancerMinuteur() {
    _minuteur?.cancel();
    _minuteur = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _attente = max(0, _attente - 1));
      if (_attente == 0) t.cancel();
    });
  }

  Future<void> _valider() async {
    if (_enCours) return;
    final code = _code.text.trim();
    if (code.length < 6) {
      setState(() => _erreur = 'Entrez le code reçu par e-mail');
      return;
    }
    setState(() {
      _enCours = true;
      _erreur = null;
      _info = null;
    });
    final erreur = await Compte.confirmer(code);
    if (!mounted) return;
    setState(() {
      _enCours = false;
      _erreur = erreur;
    });
  }

  Future<void> _renvoyer() async {
    if (_attente > 0 || _enCours) return;
    setState(() {
      _erreur = null;
      _info = null;
    });
    final erreur = await Compte.renvoyerCode();
    if (!mounted) return;
    if (erreur != null) {
      setState(() => _erreur = erreur);
      return;
    }
    setState(() => _info = 'Un nouveau code vient d\'être envoyé.');
    _demarrerAttente(60);
  }

  @override
  void dispose() {
    _minuteur?.cancel();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PageAuth(
      titre: 'Confirmez votre e-mail',
      sousTitre: Compte.emailEnAttente,
      routeRetour: '/inscription',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Un code de confirmation vient de vous être envoyé par e-mail. '
            'Entrez-le ci-dessous. Pensez à regarder dans les courriers indésirables.',
            style: TextStyle(color: Colors.black54),
          ),
          const SizedBox(height: 18),
          BandeauErreur(_erreur),
          BandeauInfo(_info),
          TextField(
            controller: _code,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 24, letterSpacing: 8),
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(10),
            ],
            onSubmitted: (_) => _valider(),
            decoration: decorationChamp('Code de confirmation', Icons.pin_outlined),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            style: styleBoutonPrincipal(),
            onPressed: _enCours ? null : _valider,
            child: _enCours ? const ChargementBouton() : const Text('Valider'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            style: styleBoutonSecondaire(),
            onPressed: _attente > 0 ? null : _renvoyer,
            child: Text(_attente > 0 ? 'Renvoyer le code ($_attente s)' : 'Renvoyer le code'),
          ),
          const SizedBox(height: 14),
          const Text(
            'Le message contient un lien au lieu d\'un code ? Cliquez sur le lien, '
            'puis revenez ici et connectez-vous.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.black45, fontSize: 12),
          ),
          TextButton(
            onPressed: () => context.go('/connexion'),
            child: const Text(
              'J\'ai déjà confirmé : me connecter',
              style: TextStyle(color: kOrange, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}

class ConnexionScreen extends StatefulWidget {
  const ConnexionScreen({super.key});

  @override
  State<ConnexionScreen> createState() => _ConnexionScreenState();
}

class _ConnexionScreenState extends State<ConnexionScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _mdp = TextEditingController();
  bool _enCours = false;
  String? _erreur;

  Future<void> _valider() async {
    if (_enCours || !_formKey.currentState!.validate()) return;
    setState(() {
      _enCours = true;
      _erreur = null;
    });
    final erreur = await Compte.connecter(_email.text, _mdp.text);
    if (!mounted) return;
    setState(() {
      _enCours = false;
      _erreur = erreur;
    });
  }

  // Compte créé mais jamais confirmé : on redemande un code puis on l'affiche
  Future<void> _saisirCode() async {
    setState(() {
      _enCours = true;
      _erreur = null;
    });
    final erreur = await Compte.renvoyerCode();
    if (!mounted) return;
    setState(() {
      _enCours = false;
      _erreur = erreur;
    });
    if (erreur == null) context.go('/confirmation');
  }

  @override
  void dispose() {
    _email.dispose();
    _mdp.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PageAuth(
      titre: 'Connexion',
      sousTitre: 'Heureux de vous revoir !',
      routeRetour: '/bienvenue',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            BandeauErreur(_erreur),
            TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              textInputAction: TextInputAction.next,
              decoration: decorationChamp('Adresse e-mail', Icons.mail_outline),
              validator: Validateurs.email,
            ),
            const SizedBox(height: 14),
            ChampMotDePasse(
              controller: _mdp,
              label: 'Mot de passe',
              action: TextInputAction.done,
              onSubmitted: (_) => _valider(),
              validator: (v) => (v ?? '').isEmpty ? 'Entrez votre mot de passe' : null,
            ),
            const SizedBox(height: 22),
            ElevatedButton(
              style: styleBoutonPrincipal(),
              onPressed: _enCours ? null : _valider,
              child: _enCours ? const ChargementBouton() : const Text('Se connecter'),
            ),
            if (Compte.confirmationRequise) ...[
              const SizedBox(height: 12),
              OutlinedButton(
                style: styleBoutonSecondaire(),
                onPressed: _enCours ? null : _saisirCode,
                child: const Text('Saisir le code de confirmation'),
              ),
            ],
            const SizedBox(height: 14),
            TextButton(
              onPressed: () => context.go('/inscription'),
              child: const Text(
                'Pas encore de compte ? Créer un compte',
                style: TextStyle(color: kOrange, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =================================================================
// SALON : choix du rôle, création (propriétaire), invitation (gérant)
// =================================================================
class _CarteChoix extends StatelessWidget {
  final IconData icone;
  final String titre;
  final String description;
  final VoidCallback onTap;

  const _CarteChoix({
    required this.icone,
    required this.titre,
    required this.description,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFFFF4EC),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFFFB27A), width: 1.2),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: const BoxDecoration(color: kRouge, shape: BoxShape.circle),
                child: Icon(icone, color: Colors.white),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      titre,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(description, style: const TextStyle(color: Colors.black54)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: kOrange),
            ],
          ),
        ),
      ),
    );
  }
}

class ChoixRoleScreen extends StatefulWidget {
  const ChoixRoleScreen({super.key});

  @override
  State<ChoixRoleScreen> createState() => _ChoixRoleScreenState();
}

class _ChoixRoleScreenState extends State<ChoixRoleScreen> {
  bool _recherche = true;

  @override
  void initState() {
    super.initState();
    Future.microtask(_chercher);
  }

  // Si ce compte a déjà un salon (nouveau téléphone, création interrompue), on le retrouve
  Future<void> _chercher() async {
    await Compte.recupererSalonExistant();
    if (!mounted) return;
    setState(() => _recherche = false);
  }

  @override
  Widget build(BuildContext context) {
    return PageAuth(
      titre: 'Vous êtes...',
      sousTitre: Compte.email,
      child: _recherche
          ? const Padding(
              padding: EdgeInsets.only(top: 40),
              child: Column(
                children: [
                  CircularProgressIndicator(color: kRouge),
                  SizedBox(height: 16),
                  Text('Recherche de votre salon...', style: TextStyle(color: Colors.black54)),
                ],
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 8),
                _CarteChoix(
                  icone: Icons.storefront_outlined,
                  titre: 'Propriétaire',
                  description: 'Je crée mon salon et j\'invite mon gérant.',
                  onTap: () => context.go('/creer-salon'),
                ),
                const SizedBox(height: 14),
                _CarteChoix(
                  icone: Icons.badge_outlined,
                  titre: 'Gérant',
                  description: 'Je rejoins un salon après l\'invitation du propriétaire.',
                  onTap: () => context.go('/rejoindre'),
                ),
              ],
            ),
    );
  }
}

class CreerSalonScreen extends StatefulWidget {
  const CreerSalonScreen({super.key});

  @override
  State<CreerSalonScreen> createState() => _CreerSalonScreenState();
}

class _CreerSalonScreenState extends State<CreerSalonScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _nomSalonController = TextEditingController();
  final TextEditingController _communeController = TextEditingController();
  final TextEditingController _telephoneController = TextEditingController();
  final TextEditingController _avenueController = TextEditingController();
  bool _enCours = false;
  String? _erreur;

  // Crée le salon en ligne (vous en devenez le propriétaire) puis sur ce téléphone
  Future<void> _creer() async {
    if (_enCours || !_formKey.currentState!.validate()) return;
    setState(() {
      _enCours = true;
      _erreur = null;
    });
    final erreur = await Compte.creerSalon(
      nom: _nomSalonController.text.trim(),
      commune: _communeController.text.trim(),
      avenue: _avenueController.text.trim(),
      telephone: Validateurs.normaliserTelephone(_telephoneController.text),
    );
    if (!mounted) return;
    setState(() {
      _enCours = false;
      _erreur = erreur;
    });
    // Succès : la navigation passe automatiquement à la création du code PIN
  }

  @override
  void dispose() {
    _nomSalonController.dispose();
    _communeController.dispose();
    _telephoneController.dispose();
    _avenueController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PageAuth(
      titre: 'Créer mon salon',
      sousTitre: 'Renseignez les informations de votre salon.',
      routeRetour: '/choix-role',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            BandeauErreur(_erreur),
            ChampsSalon(
              nomSalon: _nomSalonController,
              commune: _communeController,
              avenue: _avenueController,
              telephone: _telephoneController,
            ),
            const SizedBox(height: 26),
            ElevatedButton(
              style: styleBoutonPrincipal(),
              onPressed: _enCours ? null : _creer,
              child: _enCours ? const ChargementBouton() : const Text('Créer mon salon'),
            ),
          ],
        ),
      ),
    );
  }
}

class RejoindreScreen extends StatefulWidget {
  const RejoindreScreen({super.key});

  @override
  State<RejoindreScreen> createState() => _RejoindreScreenState();
}

class _RejoindreScreenState extends State<RejoindreScreen> {
  bool _enCours = true;
  String? _erreur;

  @override
  void initState() {
    super.initState();
    Future.microtask(_verifier);
  }

  // Cherche une invitation pour l'adresse e-mail de ce compte
  Future<void> _verifier() async {
    setState(() {
      _enCours = true;
      _erreur = null;
    });
    final erreur = await Compte.rejoindreSalon();
    if (!mounted) return;
    setState(() {
      _enCours = false;
      _erreur = erreur;
    });
    // Succès : la navigation passe automatiquement à la création du code PIN
  }

  @override
  Widget build(BuildContext context) {
    return PageAuth(
      titre: 'Rejoindre un salon',
      sousTitre: Compte.email,
      routeRetour: '/choix-role',
      child: _enCours
          ? const Padding(
              padding: EdgeInsets.only(top: 40),
              child: Column(
                children: [
                  CircularProgressIndicator(color: kRouge),
                  SizedBox(height: 16),
                  Text('Recherche de votre invitation...', style: TextStyle(color: Colors.black54)),
                ],
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                BandeauErreur(_erreur),
                const Text(
                  'Demandez au propriétaire de vous inviter avec exactement cette adresse '
                  'e-mail, puis touchez « Vérifier à nouveau ». L\'invitation est valable 14 jours.',
                  style: TextStyle(color: Colors.black54),
                ),
                const SizedBox(height: 22),
                ElevatedButton(
                  style: styleBoutonPrincipal(),
                  onPressed: _verifier,
                  child: const Text('Vérifier à nouveau'),
                ),
              ],
            ),
    );
  }
}

// Salon créé avant les comptes (version 1.2) : enregistrement en ligne
class EnvoiSalonScreen extends StatefulWidget {
  const EnvoiSalonScreen({super.key});

  @override
  State<EnvoiSalonScreen> createState() => _EnvoiSalonScreenState();
}

class _EnvoiSalonScreenState extends State<EnvoiSalonScreen> {
  bool _enCours = true;
  String? _erreur;

  @override
  void initState() {
    super.initState();
    Future.microtask(_envoyer);
  }

  Future<void> _envoyer() async {
    setState(() {
      _enCours = true;
      _erreur = null;
    });
    final erreur = await Compte.envoyerSalonExistant();
    if (!mounted) return;
    setState(() {
      _enCours = false;
      _erreur = erreur;
    });
    // Succès : la navigation continue automatiquement
  }

  @override
  Widget build(BuildContext context) {
    return PageAuth(
      titre: 'Enregistrement de votre salon',
      sousTitre: SalonData.nomSalon,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Votre salon est enregistré en ligne pour que vous puissiez inviter votre gérant '
            'et suivre l\'activité. Vos données actuelles sont conservées.',
            style: TextStyle(color: Colors.black54),
          ),
          const SizedBox(height: 22),
          if (_enCours)
            const Center(child: CircularProgressIndicator(color: kRouge))
          else ...[
            BandeauErreur(_erreur),
            ElevatedButton(
              style: styleBoutonPrincipal(),
              onPressed: _envoyer,
              child: const Text('Réessayer'),
            ),
          ],
        ],
      ),
    );
  }
}

// =================================================================
// EQUIPE (propriétaire) : inviter, annuler ou retirer le gérant
// =================================================================
class EquipeScreen extends StatefulWidget {
  const EquipeScreen({super.key});

  @override
  State<EquipeScreen> createState() => _EquipeScreenState();
}

class _EquipeScreenState extends State<EquipeScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _email = TextEditingController();
  DonneesEquipe? _donnees;
  bool _enCours = false;
  String? _erreur;

  @override
  void initState() {
    super.initState();
    _charger();
  }

  Future<void> _charger() async {
    final donnees = await Compte.chargerEquipe();
    if (!mounted) return;
    setState(() => _donnees = donnees);
  }

  Future<void> _inviter() async {
    if (_enCours || !_formKey.currentState!.validate()) return;
    setState(() {
      _enCours = true;
      _erreur = null;
    });
    final erreur = await Compte.inviterGerant(_email.text);
    if (!mounted) return;
    if (erreur == null) _email.clear();
    setState(() {
      _enCours = false;
      _erreur = erreur;
    });
    if (erreur == null) await _charger();
  }

  Future<void> _annulerInvitation(InvitationEquipe invitation) async {
    final erreur = await Compte.annulerInvitation(invitation.id);
    if (!mounted) return;
    setState(() => _erreur = erreur);
    await _charger();
  }

  Future<void> _retirerGerant(MembreEquipe gerant) async {
    final confirme = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Retirer le gérant ?'),
        content: Text(
          '${gerant.email} n\'aura plus accès au salon. Vous pourrez inviter un autre gérant ensuite.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: kRouge,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Retirer'),
          ),
        ],
      ),
    );
    if (confirme != true || !mounted) return;
    final erreur = await Compte.retirerMembre(gerant.userId);
    if (!mounted) return;
    setState(() => _erreur = erreur);
    await _charger();
  }

  Widget _ligne(IconData icone, String titre, String texte, {Widget? action}) {
    return Card(
      elevation: 0,
      color: const Color(0xFFFFF4EC),
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0xFFFFB27A)),
      ),
      child: ListTile(
        leading: Icon(icone, color: kRouge),
        title: Text(titre, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(texte),
        trailing: action,
      ),
    );
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final donnees = _donnees;
    final proprietaires =
        donnees?.membres.where((m) => m.role == 'proprietaire').toList() ?? <MembreEquipe>[];
    final gerants = donnees?.membres.where((m) => m.role == 'gerant').toList() ?? <MembreEquipe>[];
    final invitations = donnees?.invitations ?? <InvitationEquipe>[];

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) context.go('/profil');
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Mon équipe'),
          backgroundColor: kRouge,
          foregroundColor: Colors.white,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => context.go('/profil'),
          ),
        ),
        body: donnees == null
            ? const Center(child: CircularProgressIndicator(color: kRouge))
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  BandeauErreur(donnees.erreur ?? _erreur),
                  if (donnees.erreur != null)
                    OutlinedButton(
                      style: styleBoutonSecondaire(),
                      onPressed: _charger,
                      child: const Text('Réessayer'),
                    ),
                  for (final p in proprietaires)
                    _ligne(Icons.storefront_outlined, 'Propriétaire', p.email),
                  for (final g in gerants)
                    _ligne(
                      Icons.badge_outlined,
                      'Gérant',
                      g.email,
                      action: IconButton(
                        tooltip: 'Retirer le gérant',
                        icon: const Icon(Icons.person_remove_outlined, color: kRouge),
                        onPressed: () => _retirerGerant(g),
                      ),
                    ),
                  for (final i in invitations)
                    _ligne(
                      Icons.hourglass_top_outlined,
                      'Invitation en attente',
                      i.email,
                      action: IconButton(
                        tooltip: 'Annuler l\'invitation',
                        icon: const Icon(Icons.close, color: kRouge),
                        onPressed: () => _annulerInvitation(i),
                      ),
                    ),
                  const SizedBox(height: 14),
                  if (gerants.isEmpty && donnees.erreur == null)
                    Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'Inviter mon gérant',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Entrez l\'adresse e-mail de votre gérant. Il devra créer son compte avec '
                            'exactement cette adresse. Prévenez-le par WhatsApp : l\'invitation n\'envoie pas d\'e-mail.',
                            style: TextStyle(color: Colors.black54),
                          ),
                          const SizedBox(height: 14),
                          TextFormField(
                            controller: _email,
                            keyboardType: TextInputType.emailAddress,
                            autocorrect: false,
                            decoration: decorationChamp('Adresse e-mail du gérant', Icons.mail_outline),
                            validator: Validateurs.email,
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton(
                            style: styleBoutonPrincipal(),
                            onPressed: _enCours ? null : _inviter,
                            child: _enCours ? const ChargementBouton() : const Text('Inviter'),
                          ),
                        ],
                      ),
                    ),
                  if (gerants.isNotEmpty)
                    const BandeauInfo(
                      'Pour changer de gérant, retirez d\'abord le gérant actuel, puis invitez le nouveau.',
                    ),
                ],
              ),
      ),
    );
  }
}

// =================================================================
// CODE PIN : création (première fois) et saisie (à chaque ouverture)
// =================================================================
class CreerPinScreen extends StatefulWidget {
  const CreerPinScreen({super.key});

  @override
  State<CreerPinScreen> createState() => _CreerPinScreenState();
}

class _CreerPinScreenState extends State<CreerPinScreen> {
  final TextEditingController _pin = TextEditingController();
  final TextEditingController _confirmation = TextEditingController();
  String? _erreur;
  bool _enCours = false;

  Future<void> _valider() async {
    if (_enCours) return;
    final erreurFormat = PinService.erreurDeFormat(_pin.text);
    if (erreurFormat != null) {
      setState(() => _erreur = erreurFormat);
      return;
    }
    if (_pin.text != _confirmation.text) {
      setState(() => _erreur = 'Les deux codes ne correspondent pas');
      return;
    }
    setState(() {
      _enCours = true;
      _erreur = null;
    });
    final ok = await PinService.definir(_pin.text);
    if (!mounted) return;
    if (ok) {
      Session.instance.definirPin(); // déverrouille et ouvre le tableau de bord
    } else {
      setState(() {
        _enCours = false;
        _erreur = 'Impossible d\'enregistrer le code sur ce téléphone. Réessayez.';
      });
    }
  }

  @override
  void dispose() {
    _pin.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Créer votre code PIN'),
        backgroundColor: kRouge,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, size: 56, color: kRouge),
              const SizedBox(height: 12),
              Text(
                'Ce code protège l\'accès à l\'application. Il sera demandé à chaque '
                'ouverture, et après ${kDelaiVerrouillage.inMinutes} minute(s) passée(s) en arrière-plan.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 8),
              const Text(
                'Notez-le bien : dans cette version de test, il ne peut pas être récupéré.',
                textAlign: TextAlign.center,
                style: TextStyle(color: kOrange, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 24),
              ChampPin(controller: _pin, label: 'Code PIN (4 chiffres)', autofocus: true),
              const SizedBox(height: 16),
              ChampPin(controller: _confirmation, label: 'Confirmer le code'),
              if (_erreur != null) ...[
                const SizedBox(height: 12),
                Text(_erreur!, textAlign: TextAlign.center, style: const TextStyle(color: kRouge)),
              ],
              const SizedBox(height: 24),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: kRouge,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(50),
                ),
                onPressed: _enCours ? null : _valider,
                child: const Text('Enregistrer le code', style: TextStyle(fontSize: 18)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PinScreen extends StatefulWidget {
  const PinScreen({super.key});

  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  final TextEditingController _controller = TextEditingController();
  Timer? _minuteur;
  int _secondesVerrou = 0;
  String? _erreur;
  bool _verification = false;

  @override
  void initState() {
    super.initState();
    _actualiserVerrou();
  }

  // Affiche le compte à rebours si l'accès est bloqué après trop d'erreurs
  Future<void> _actualiserVerrou() async {
    final secondes = await PinService.secondesDeVerrou();
    if (!mounted) return;
    _minuteur?.cancel();
    setState(() => _secondesVerrou = secondes);
    if (secondes > 0) {
      _minuteur = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        setState(() => _secondesVerrou = max(0, _secondesVerrou - 1));
        if (_secondesVerrou == 0) t.cancel();
      });
    }
  }

  Future<void> _verifier(String pin) async {
    if (_verification || _secondesVerrou > 0) return;
    setState(() {
      _verification = true;
      _erreur = null;
    });
    final resultat = await PinService.verifier(pin);
    if (!mounted) return;
    if (resultat.ok) {
      Session.instance.deverrouiller(); // la navigation ouvre le tableau de bord
      return;
    }
    _controller.clear();
    setState(() {
      _verification = false;
      if (resultat.erreurTechnique) {
        _erreur = 'Vérification impossible. Réessayez.';
      } else if (resultat.secondesVerrou > 0) {
        _erreur = 'Trop d\'essais incorrects.';
      } else {
        _erreur = 'Code incorrect (${resultat.tentativesRestantes} essai(s) avant blocage)';
      }
    });
    if (resultat.secondesVerrou > 0) await _actualiserVerrou();
  }

  void _codeOublie() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Code PIN oublié ?'),
          content: const Text(
            'Dans cette version de test, le code est protégé sur ce téléphone et ne peut pas '
            'être récupéré.\n\n'
            'Pour repartir de zéro : Paramètres du téléphone > Applications > Coif-Hair > '
            'Stockage > Effacer les données.\n\n'
            'Attention : cela efface aussi toutes les données du salon enregistrées sur ce téléphone.',
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: kRouge,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(context),
              child: const Text('Compris'),
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _minuteur?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bloque = _secondesVerrou > 0;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 64, color: kRouge),
                const SizedBox(height: 12),
                const Text(
                  'COIF-HAIR',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: kRouge),
                ),
                const SizedBox(height: 4),
                Text(
                  SalonData.nomSalon,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 28),
                ChampPin(
                  controller: _controller,
                  label: 'Code PIN',
                  autofocus: true,
                  enabled: !bloque && !_verification,
                  onChanged: (valeur) {
                    if (valeur.length == 4) _verifier(valeur);
                  },
                ),
                if (_erreur != null) ...[
                  const SizedBox(height: 12),
                  Text(_erreur!, textAlign: TextAlign.center, style: const TextStyle(color: kRouge)),
                ],
                if (bloque) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Réessayez dans $_secondesVerrou s',
                    style: const TextStyle(color: kOrange, fontWeight: FontWeight.bold),
                  ),
                ],
                const SizedBox(height: 16),
                TextButton(
                  onPressed: _codeOublie,
                  child: const Text('Code oublié ?', style: TextStyle(color: Colors.grey)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =================================================================
// PROFIL DU SALON : modifier les données saisies à la connexion
// =================================================================
class ProfilScreen extends StatefulWidget {
  const ProfilScreen({super.key});

  @override
  State<ProfilScreen> createState() => _ProfilScreenState();
}

class _ProfilScreenState extends State<ProfilScreen> {
  final _formKey = GlobalKey<FormState>();
  // Les champs sont pré-remplis avec les données enregistrées
  final TextEditingController _nomSalonController =
      TextEditingController(text: SalonData.nomSalon);
  final TextEditingController _communeController =
      TextEditingController(text: SalonData.commune);
  final TextEditingController _avenueController =
      TextEditingController(text: SalonData.avenue);
  final TextEditingController _telephoneController =
      TextEditingController(text: SalonData.telephone);

  Future<void> _enregistrer() async {
    if (!SalonData.estProprietaire) return; // seul le propriétaire modifie le salon
    if (!_formKey.currentState!.validate()) return;

    // L'identifiant du salon (salonId) ne change jamais
    SalonData.nomSalon = _nomSalonController.text.trim();
    SalonData.commune = _communeController.text.trim();
    SalonData.avenue = _avenueController.text.trim();
    SalonData.telephone = Validateurs.normaliserTelephone(_telephoneController.text);
    unawaited(SalonData.sauvegarder());

    // Mise à jour en ligne (le propriétaire voit les mêmes informations partout)
    final erreur = await Compte.mettreAJourSalon();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          erreur == null
              ? 'Informations du salon mises à jour'
              : 'Enregistré sur ce téléphone. Mise à jour en ligne impossible : $erreur',
        ),
      ),
    );
    context.go('/dashboard');
  }

  // Changement du code PIN : il faut d'abord saisir l'ancien
  Future<void> _changerPin() async {
    final ancien = TextEditingController();
    final nouveau = TextEditingController();
    final confirmation = TextEditingController();
    String? erreur;
    bool enCours = false;

    final modifie = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setStateDialog) {
            return AlertDialog(
              title: const Text('Changer le code PIN'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ChampPin(controller: ancien, label: 'Code actuel', autofocus: true),
                    const SizedBox(height: 12),
                    ChampPin(controller: nouveau, label: 'Nouveau code'),
                    const SizedBox(height: 12),
                    ChampPin(controller: confirmation, label: 'Confirmer le nouveau code'),
                    if (erreur != null) ...[
                      const SizedBox(height: 12),
                      Text(erreur!, style: const TextStyle(color: kRouge)),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Annuler', style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kRouge,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: enCours
                      ? null
                      : () async {
                          final erreurFormat = PinService.erreurDeFormat(nouveau.text);
                          if (erreurFormat != null) {
                            setStateDialog(() => erreur = erreurFormat);
                            return;
                          }
                          if (nouveau.text != confirmation.text) {
                            setStateDialog(() => erreur = 'Les deux codes ne correspondent pas');
                            return;
                          }
                          setStateDialog(() {
                            enCours = true;
                            erreur = null;
                          });
                          final resultat = await PinService.verifier(ancien.text);
                          if (!ctx.mounted) return;
                          if (!resultat.ok) {
                            setStateDialog(() {
                              enCours = false;
                              if (resultat.erreurTechnique) {
                                erreur = 'Vérification impossible. Réessayez.';
                              } else if (resultat.secondesVerrou > 0) {
                                erreur = 'Trop d\'essais. Réessayez dans ${resultat.secondesVerrou} s.';
                              } else {
                                erreur = 'Code actuel incorrect';
                              }
                            });
                            return;
                          }
                          final ok = await PinService.definir(nouveau.text);
                          if (!ctx.mounted) return;
                          if (ok) {
                            Navigator.pop(ctx, true);
                          } else {
                            setStateDialog(() {
                              enCours = false;
                              erreur = 'Impossible d\'enregistrer le nouveau code.';
                            });
                          }
                        },
                  child: const Text('Enregistrer'),
                ),
              ],
            );
          },
        );
      },
    );

    if (modifie == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Code PIN modifié')),
      );
    }
  }

  @override
  void dispose() {
    _nomSalonController.dispose();
    _communeController.dispose();
    _avenueController.dispose();
    _telephoneController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) context.go('/dashboard');
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Mon profil'),
          backgroundColor: kRouge,
          foregroundColor: Colors.white,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => context.go('/dashboard'),
          ),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20.0),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Informations du salon',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  SalonData.estProprietaire
                      ? 'Modifiez les informations de votre salon.'
                      : 'Seul le propriétaire peut modifier ces informations.',
                  style: const TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 24),
                ChampsSalon(
                  nomSalon: _nomSalonController,
                  commune: _communeController,
                  avenue: _avenueController,
                  telephone: _telephoneController,
                  enabled: SalonData.estProprietaire,
                ),
                const SizedBox(height: 12),
                Text(
                  'Identifiant du salon : ${SalonData.salonId}',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
                const SizedBox(height: 24),
                if (SalonData.estProprietaire) ...[
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kRouge,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(50),
                    ),
                    onPressed: _enregistrer,
                    child: const Text('Enregistrer', style: TextStyle(fontSize: 18)),
                  ),
                  const SizedBox(height: 12),
                ],
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kRouge,
                    side: const BorderSide(color: kRouge),
                    minimumSize: const Size.fromHeight(50),
                  ),
                  onPressed: _changerPin,
                  icon: const Icon(Icons.lock_outline),
                  label: const Text('Changer le code PIN'),
                ),
                if (SalonData.estProprietaire) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: kRouge,
                      side: const BorderSide(color: kRouge),
                      minimumSize: const Size.fromHeight(50),
                    ),
                    onPressed: () => context.go('/equipe'),
                    icon: const Icon(Icons.group_outlined),
                    label: const Text('Mon équipe : inviter mon gérant'),
                  ),
                ],
                const SizedBox(height: 24),
                Text(
                  'Compte : ${Compte.email}',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
                Text(
                  'Rôle : ${SalonData.estProprietaire ? 'propriétaire' : 'gérant'}',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =================================================================
// TABLEAU DE BORD : chiffres DU JOUR, calculés à partir du journal
// =================================================================
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  // Fonction pour renommer un coiffeur directement en cliquant dessus
  void renommerCoiffeur(BuildContext context, int index) {
    final TextEditingController controller = TextEditingController(
      text: SalonData.coiffeurs[index]['nom'],
    );

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Modifier le nom'),
          content: TextField(
            controller: controller,
            inputFormatters: [LengthLimitingTextInputFormatter(20)],
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Nom du coiffeur',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Annuler', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: kRouge,
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                if (controller.text.trim().isNotEmpty) {
                  setState(() {
                    SalonData.coiffeurs[index]['nom'] = controller.text.trim();
                  });
                  await SalonData.sauvegarder();
                  final enLigne = await SalonData.renommerCoiffeurEnLigne(index);
                  if (!context.mounted) return;
                  if (SalonData.salonEnLigne && !enLigne) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Nom sauvegardé localement, mais en ligne non synchronisé.')));
                  }
                  Navigator.pop(context);
                }
              },
              child: const Text('Enregistrer'),
            ),
          ],
        );
      },
    );
  }

  // Fonction pour afficher le message de blocage de la version gratuite
  void _afficherAlertePaywall(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Version d\'essai expirée '),
          content: const Text(
            'Vous avez atteint la limite de 50 clients de la version gratuite.\n\nVeuillez contacter le développeur pour passer à la version payante et débloquer un accès illimité !',
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: kRouge,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(context),
              child: const Text('Compris'),
            ),
          ],
        );
      },
    );
  }

  // Fonction d'ajout de prestation
  void afficherDialogueAjoutClient(BuildContext context, VoidCallback onUpdate) {
    // Le coiffeur est choisi par sa POSITION dans la liste (et non par son nom) :
    // deux coiffeurs portant le même nom ne posent donc plus de problème.
    int coiffeurSelectionne = 0;
    final TextEditingController montantController = TextEditingController();
    double noteAttribuee = 5.0;
    String? erreurMontant;
    bool dejaValide = false; // empêche un double enregistrement en cas de double clic

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: const Text('Ajouter une prestation'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Choisir le coiffeur :', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<int>(
                      initialValue: coiffeurSelectionne,
                      isExpanded: true,
                      items: List.generate(SalonData.coiffeurs.length, (i) {
                        return DropdownMenuItem<int>(
                          value: i,
                          child: Text(
                            SalonData.coiffeurs[i]['nom'] as String,
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      }),
                      onChanged: (val) {
                        if (val != null) {
                          setStateDialog(() {
                            coiffeurSelectionne = val;
                          });
                        }
                      },
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: montantController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(9),
                      ],
                      decoration: InputDecoration(
                        labelText: 'Montant perçu (CDF)',
                        border: const OutlineInputBorder(),
                        errorText: erreurMontant,
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Text('Note du client :', style: TextStyle(fontWeight: FontWeight.bold)),
                    Slider(
                      value: noteAttribuee,
                      min: 1.0,
                      max: 5.0,
                      divisions: 4,
                      label: noteAttribuee.toString(),
                      activeColor: kOrange,
                      onChanged: (val) {
                        setStateDialog(() {
                          noteAttribuee = val;
                        });
                      },
                    ),
                    Center(
                      child: Text(
                        '${noteAttribuee.toStringAsFixed(1)} ⭐',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: kOrange),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Annuler', style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kRouge,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () async {
                    if (dejaValide) return;

                    final int? montant = SalonData.lireMontant(montantController.text);
                    if (montant == null) {
                      setStateDialog(() {
                        erreurMontant = 'Entrez un montant valide en CDF';
                      });
                      return;
                    }

                    dejaValide = true;
                    // Une nouvelle ligne est ajoutée au journal (et enregistrée)
                    await SalonData.ajouterPrestation(
                      coiffeur: coiffeurSelectionne,
                      montant: montant,
                      note: noteAttribuee,
                    );

                    Navigator.pop(context);
                    onUpdate();
                  },
                  child: const Text('Valider'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Récupération de la date du système en temps réel
    final now = DateTime.now();
    final String dateDuJour = formaterDate(now);
    // Tous les chiffres affichés sont ceux d'AUJOURD'HUI
    final bilan = SalonData.bilanDuJour(now);
    final cote = bilan.cote;

    return Scaffold(
      backgroundColor: Colors.grey[100],
      body: SafeArea(
        child: Column(
          children: [
            // --- EN-TÊTE ROUGE ---
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16.0),
              color: kRouge,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'COIF-HAIR',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          SalonData.nomSalon,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Verrouiller l'application tout de suite
                  IconButton(
                    icon: const Icon(Icons.lock_outline, color: Colors.white),
                    onPressed: () => Session.instance.verrouiller(),
                    tooltip: 'Verrouiller',
                  ),
                  // Icône Historique
                  IconButton(
                    icon: const Icon(Icons.history, color: Colors.white),
                    onPressed: () => context.go('/history'),
                    tooltip: 'Historique',
                  ),
                ],
              ),
            ),

            // --- INDICATEURS (Date + Badges Orange compacts + Icônes User & Caisse) ---
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'DATE : $dateDuJour',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Colors.black,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
                            decoration: BoxDecoration(
                              color: kOrange,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              'CLIENTS : ${bilan.clients.toString().padLeft(2, '0')}',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
                            decoration: BoxDecoration(
                              color: kOrange,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              'CÔTE MOYENNE : ${cote == null ? '-' : cote.toStringAsFixed(1)}',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      // Icône utilisateur : ouvre l'écran de modification du profil
                      Tooltip(
                        message: 'Mon profil',
                        child: GestureDetector(
                          onTap: () => context.go('/profil'),
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.grey.shade400, width: 1.5),
                            ),
                            child: const Icon(Icons.person_outline, color: Colors.black87, size: 22),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () => context.go('/caisse'),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.red.shade50,
                            border: Border.all(color: kRouge, width: 1.5),
                          ),
                          child: const Icon(Icons.point_of_sale, color: kRouge, size: 22),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // --- GRILLE DÉFILANTE DES COIFFEURS ---
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 1.05,
                  ),
                  itemCount: SalonData.coiffeurs.length,
                  itemBuilder: (context, index) {
                    final coiffeur = SalonData.coiffeurs[index];
                    return Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.grey.withValues(alpha: 0.1),
                            spreadRadius: 1,
                            blurRadius: 3,
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          GestureDetector(
                            onTap: () => renommerCoiffeur(context, index),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8.0),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Flexible(
                                    child: Text(
                                      coiffeur['nom'],
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: kRouge,
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  const Icon(Icons.edit, size: 14, color: Colors.grey),
                                ],
                              ),
                            ),
                          ),

                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(coiffeur['icone'], color: kRouge, size: 28),
                              const SizedBox(width: 8),
                              Text(
                                bilan.parCoiffeur[index].toString().padLeft(2, '0'),
                                style: const TextStyle(
                                  color: kOrange,
                                  fontSize: 38,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const Text(
                            'Clients',
                            style: TextStyle(color: Colors.grey, fontSize: 13),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),

            // FONCTION BOUTON D'ACTION EN BAS ("Ajouter une prestation") ---
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Center(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: kRouge, width: 2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: TextButton.icon(
                    onPressed: () {
                      // Vérification de la limite de la version gratuite (tous clients confondus)
                      if (SalonData.totalPrestationsEnregistrees >= 50) {
                        _afficherAlertePaywall(context);
                      } else {
                        afficherDialogueAjoutClient(context, () {
                          if (mounted) {
                            setState(() {}); // rafraîchit l'écran du tableau de bord
                          }
                        });
                      }
                    },
                    icon: const Icon(Icons.add, color: kRouge),
                    label: const Text(
                      'Ajouter une prestation',
                      style: TextStyle(
                        color: kRouge,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =================================================================
// ÉCRAN CAISSE : entrées et sorties du jour, solde cumulé
// =================================================================
class CaisseScreen extends StatefulWidget {
  const CaisseScreen({super.key});

  @override
  State<CaisseScreen> createState() => _CaisseScreenState();
}

class _CaisseScreenState extends State<CaisseScreen> {
  void afficherDialogueDepense(BuildContext context) {
    final TextEditingController montantController = TextEditingController();
    final TextEditingController explicationController = TextEditingController();
    String? erreurMontant;
    String? erreurExplication;
    bool dejaValide = false; // empêche un double enregistrement en cas de double clic

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: const Text('Enregistrer une dépense'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: montantController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(9),
                      ],
                      decoration: InputDecoration(
                        labelText: 'Montant (CDF)',
                        border: const OutlineInputBorder(),
                        errorText: erreurMontant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: explicationController,
                      inputFormatters: [LengthLimitingTextInputFormatter(60)],
                      decoration: InputDecoration(
                        labelText: 'Explication',
                        border: const OutlineInputBorder(),
                        errorText: erreurExplication,
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Annuler', style: TextStyle(color: Colors.grey)),
                ),
                IconButton(
                  icon: const Icon(Icons.check_circle, color: kRouge, size: 36),
                  onPressed: () async {
                    if (dejaValide) return;

                    final int? montant = SalonData.lireMontant(montantController.text);
                    final String explication = explicationController.text.trim();
                    if (montant == null || explication.isEmpty) {
                      setStateDialog(() {
                        erreurMontant = montant == null ? 'Entrez un montant valide en CDF' : null;
                        erreurExplication = explication.isEmpty ? 'Indiquez le motif de la dépense' : null;
                      });
                      return;
                    }

                    dejaValide = true;
                    await SalonData.ajouterDepense(montant: montant, explication: explication);
                    Navigator.pop(context);
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final bilan = SalonData.bilanDuJour(DateTime.now());

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) context.go('/dashboard');
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Caisse'),
          backgroundColor: kRouge,
          foregroundColor: Colors.white,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => context.go('/dashboard'),
          ),
        ),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Entrées et Sorties du jour côte à côte
              Row(
                children: [
                  Expanded(
                    child: Card(
                      elevation: 2,
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Entrées du jour', style: TextStyle(color: Colors.grey, fontSize: 14)),
                            const SizedBox(height: 8),
                            Text(formaterMontant(bilan.entrees), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.green)),
                            const Text('CDF', style: TextStyle(color: Colors.grey, fontSize: 12)),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Card(
                      elevation: 2,
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Sorties du jour', style: TextStyle(color: Colors.grey, fontSize: 14)),
                            const SizedBox(height: 8),
                            Text(formaterMontant(bilan.sorties), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: kRouge)),
                            const Text('CDF', style: TextStyle(color: Colors.grey, fontSize: 12)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // Solde net en caisse (toutes les journées cumulées)
              Card(
                elevation: 2,
                color: Colors.orange.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Solde net en Caisse', style: TextStyle(color: kOrange, fontSize: 14, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Text('${formaterMontant(SalonData.soldeCaisse)} CDF', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: kOrange)),
                      const SizedBox(height: 4),
                      const Text('Cumul de toutes les journées', style: TextStyle(color: Colors.grey, fontSize: 12)),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              // Bouton pour ajouter une dépense
              Center(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: kRouge, width: 2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: TextButton.icon(
                    onPressed: () => afficherDialogueDepense(context),
                    icon: const Icon(Icons.add_circle_outline, color: kRouge),
                    label: const Text(
                      'Ajouter une dépense',
                      style: TextStyle(color: kRouge, fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =================================================================
// ÉCRAN HISTORIQUE : une ligne par journée, calculée à partir du journal
// =================================================================
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final bilans = SalonData.tousLesBilans();
    final aReport = SalonData.aUnReport;
    final nombreLignes = bilans.length + (aReport ? 1 : 0);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) context.go('/dashboard');
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Historique des journées'),
          backgroundColor: kRouge,
          foregroundColor: Colors.white,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => context.go('/dashboard'),
          ),
        ),
        body: nombreLignes == 0
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24.0),
                  child: Text(
                    'Aucune opération enregistrée pour le moment.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.all(16.0),
                itemCount: nombreLignes,
                itemBuilder: (context, index) {
                  // Dernière ligne : données des anciennes versions (avant le journal)
                  if (index >= bilans.length) {
                    final clientsAvant =
                        SalonData.reportClients.fold<int>(0, (somme, c) => somme + c);
                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: ListTile(
                        title: const Text(
                          'Avant le journal',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 6.0),
                          child: Text(
                            'Clients : $clientsAvant\n'
                            'Dépenses : ${formaterMontant(SalonData.reportSorties)} CDF',
                            style: const TextStyle(color: Colors.black87),
                          ),
                        ),
                        trailing: Text(
                          '${formaterMontant(SalonData.reportEntrees)} CDF',
                          style: const TextStyle(
                            color: Colors.green,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    );
                  }

                  final jour = bilans[index];
                  final cote = jour.cote;
                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: ListTile(
                      onTap: () => context.go('/history/${jour.cle}'),
                      title: Text(
                        'Date : ${formaterDate(jour.date)}',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 6.0),
                        child: Text(
                          'Clients : ${jour.clients} | Côte : ${cote == null ? '-' : cote.toStringAsFixed(1)} ⭐\n'
                          'Dépenses : ${formaterMontant(jour.sorties)} CDF'
                          '${jour.annulations > 0 ? ' | Annulées : ${jour.annulations}' : ''}',
                          style: const TextStyle(color: Colors.black87),
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${formaterMontant(jour.entrees)} CDF',
                            style: const TextStyle(
                              color: Colors.green,
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                          const Icon(Icons.chevron_right, color: Colors.grey),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

// Détail d'une journée : toutes les opérations, de la plus récente à la plus ancienne
class JourScreen extends StatefulWidget {
  final String cle;
  const JourScreen({super.key, required this.cle});

  @override
  State<JourScreen> createState() => _JourScreenState();
}

class _JourScreenState extends State<JourScreen> {
  // Annulation d'une erreur de saisie : motif + code PIN obligatoires
  Future<void> _demanderAnnulation(Operation op) async {
    final motif = TextEditingController();
    final pin = TextEditingController();
    String? erreur;
    bool enCours = false;
    final estPrestation = op.type == TypeOperation.prestation;
    final description = estPrestation
        ? 'Prestation de ${formaterMontant(op.montant)} CDF (${SalonData.coiffeurs[op.coiffeur]['nom']})'
        : 'Dépense de ${formaterMontant(op.montant)} CDF (${op.explication})';

    final annulee = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setStateDialog) {
            return AlertDialog(
              title: const Text('Annuler cette opération ?'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(description, style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    const Text(
                      'Elle restera visible dans l\'historique, barrée, mais ne sera plus comptée. '
                      'Cette action est définitive.',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: motif,
                      inputFormatters: [LengthLimitingTextInputFormatter(60)],
                      decoration: const InputDecoration(
                        labelText: 'Motif de l\'annulation',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ChampPin(controller: pin, label: 'Code PIN pour confirmer'),
                    if (erreur != null) ...[
                      const SizedBox(height: 12),
                      Text(erreur!, style: const TextStyle(color: kRouge)),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Retour', style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kRouge,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: enCours
                      ? null
                      : () async {
                          if (motif.text.trim().isEmpty) {
                            setStateDialog(() => erreur = 'Indiquez le motif de l\'annulation');
                            return;
                          }
                          if (pin.text.length != 4) {
                            setStateDialog(() => erreur = 'Entrez votre code PIN à 4 chiffres');
                            return;
                          }
                          setStateDialog(() {
                            enCours = true;
                            erreur = null;
                          });
                          final resultat = await PinService.verifier(pin.text);
                          if (!ctx.mounted) return;
                          if (!resultat.ok) {
                            setStateDialog(() {
                              enCours = false;
                              pin.clear();
                              if (resultat.erreurTechnique) {
                                erreur = 'Vérification impossible. Réessayez.';
                              } else if (resultat.secondesVerrou > 0) {
                                erreur = 'Trop d\'essais. Réessayez dans ${resultat.secondesVerrou} s.';
                              } else {
                                erreur = 'Code PIN incorrect';
                              }
                            });
                            return;
                          }
                          final ok = await SalonData.annulerOperation(op.id, motif.text);
                          if (!ctx.mounted) return;
                          if (ok) {
                            Navigator.pop(ctx, true);
                          } else {
                            setStateDialog(() {
                              enCours = false;
                              erreur = 'Cette opération ne peut plus être annulée.';
                            });
                          }
                        },
                  child: const Text('Annuler l\'opération'),
                ),
              ],
            );
          },
        );
      },
    );

    if (annulee == true && mounted) {
      setState(() {}); // rafraîchit la liste : l'opération apparaît barrée
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Opération annulée')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final date = SalonData.dateDeCle(widget.cle);
    final operations = date == null ? <Operation>[] : SalonData.operationsDuJour(widget.cle);
    final uneAnnulationPossible = operations.any(SalonData.peutEtreAnnulee);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) context.go('/history');
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(date == null ? 'Journée' : formaterDate(date)),
          backgroundColor: kRouge,
          foregroundColor: Colors.white,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => context.go('/history'),
          ),
        ),
        body: operations.isEmpty
            ? const Center(
                child: Text(
                  'Aucune opération pour cette journée.',
                  style: TextStyle(color: Colors.grey),
                ),
              )
            : Column(
                children: [
                  if (uneAnnulationPossible)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Text(
                        'Touchez une opération pour l\'annuler en cas d\'erreur.',
                        style: TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                    ),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.all(16.0),
                      itemCount: operations.length,
                      itemBuilder: (context, index) {
                        final op = operations[index];
                        final estPrestation = op.type == TypeOperation.prestation;
                        final annulee = op.annulee;
                        final nomCoiffeur = estPrestation
                            ? SalonData.coiffeurs[op.coiffeur]['nom'] as String
                            : '';
                        final couleur = annulee
                            ? Colors.grey
                            : (estPrestation ? Colors.green : kRouge);
                        final barre = annulee ? TextDecoration.lineThrough : TextDecoration.none;
                        final detail = estPrestation
                            ? '${formaterHeure(op.date)} | Note : ${op.note.toStringAsFixed(1)} ⭐'
                            : '${formaterHeure(op.date)} | Dépense';
                        return Card(
                          margin: const EdgeInsets.only(bottom: 10),
                          child: ListTile(
                            onTap: SalonData.peutEtreAnnulee(op)
                                ? () => _demanderAnnulation(op)
                                : null,
                            leading: Icon(
                              estPrestation ? Icons.content_cut : Icons.shopping_bag_outlined,
                              color: couleur,
                            ),
                            title: Text(
                              estPrestation ? 'Prestation - $nomCoiffeur' : op.explication,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: annulee ? Colors.grey : null,
                                decoration: barre,
                              ),
                            ),
                            subtitle: Text(
                              annulee
                                  ? '$detail\nAnnulée à ${formaterHeure(op.annuleeLe!)} : ${op.motifAnnulation}'
                                  : detail,
                            ),
                            trailing: Text(
                              '${estPrestation ? '+' : '-'}${formaterMontant(op.montant)} CDF',
                              style: TextStyle(
                                color: couleur,
                                fontWeight: FontWeight.bold,
                                decoration: barre,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
