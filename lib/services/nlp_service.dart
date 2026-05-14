/// Turkce isaret dili NLP servisi
class NlpService {
  // Turkish character normalization
  static String normTR(String s) {
    return s.toUpperCase()
        .replaceAll('İ', 'I').replaceAll('Ş', 'S').replaceAll('Ç', 'C')
        .replaceAll('Ö', 'O').replaceAll('Ü', 'U').replaceAll('Ğ', 'G')
        .replaceAll('ı', 'I').replaceAll('ş', 'S').replaceAll('ç', 'C')
        .replaceAll('ö', 'O').replaceAll('ü', 'U').replaceAll('ğ', 'G');
  }

  // Turkish suffixes (longest first)
  static const List<String> _suffixes = [
    'DAYDIM','DEYDIM','TAYDIN','TEYDIN','DAYDIK','DEYDIK',
    'DAYDIN','DEYDIN','DAYDI','DEYDI',
    'IYORUM','IYORSUN','UYORUM','UYORSUN',
    'IYORUZ','UYORUZ','IYORLAR','UYORLAR',
    // Aorist (gorusur, gorusuruz, gorusurum...)
    'IRSUNUZ','URSUNUZ','ARSUNUZ','ERSUNUZ',
    'IRSINIZ','ARSINIZ','ERSINIZ',
    'IRLAR','URLAR','ARLAR','ERLAR',
    'IRSUN','URSUN','ARSIN','ERSIN',
    'IRUM','URUM','ARIM','ERIM',
    'IRIZ','URUZ','ARIZ','ERIZ',
    // Cohortative (icelim, yapalim, yiyelim)
    'YELIM','YALIM','ELIM','ALIM',
    // Past tense (yoruldum, gittim, yaptin)
    'DIM','DUM','DIN','DUN','TIM','TUM','TIN','TUN',
    'DIK','DUK','TIK','TUK','DILER','TILER','DULER','TULER',
    'LARINA','LERINE','LARINI','LERINI','LARIMIZ','LERIMIZ',
    'LARDAN','LERDEN','LARIN','LERIN','LARI','LERI','LARA','LERE',
    'IMIZI','INIZI','UMUZ','UNUZ','MIZI','NIZI',
    'SINI','SINE','INDA','INDE','NDAN','NDEN','IYOR','UYOR',
    'SINIZ','SUNUZ','ACAK','ECEK','ACAGIM','ECEGIM',
    'ININ','UNUN',
    'MISTIM','MUSTUM','MISTIN','MUSTUN',
    'MISTI','MUSTU','MISTIK','MUSTUK',
    'DAN','DEN','TAN','TEN',
    'YOR','MIS','MUS','DIR','TIR','DUR','TUR',
    'SIN','SUN','YIM','YUM','YIZ','YUZ',
    'INA','INE','UNA','UNE',
    'INI','UNU','NIN','NUN',
    'DA','DE','TA','TE',
    'DI','DU','TI','TU',
    'IM','UM','IN','UN','IZ','UZ',
    'YI','YU','YA','YE',
    'MI','MU','SI','SU',
    'LA','LE','CI','CU','LI','LU',
    'I','U','A','E',
  ];

  // Gloss -> Turkish display
  static const Map<String, String> glossToTR = {
    'ABI':'Abi','ABLA':'Abla','AFERIN':'Aferin','AGUSTOS':'Ağustos',
    'AKILLI':'Akıllı','AKRABA':'Akraba','AKSAM':'Akşam','ALERJI':'Alerji',
    'ALLAH':'Allah','ALTI':'Altı','AMCA':'Amca','AMIN':'Amin','ANNE':'Anne',
    'APTAL':'Aptal','ARALIK':'Aralık','ARAP':'Arap','ARKADAS':'Arkadaş',
    'ASK':'Aşk','ATATURK':'Atatürk','AYIP':'Ayıp','AYRAN':'Ayran',
    'BABA':'Baba','BAKLAVA':'Baklava','BARIS':'Barış','BEN':'Ben',
    'BES':'Beş','BILGISAYAR':'Bilgisayar','BIR':'Bir','BOS VERMEK':'Boş vermek',
    'BU KADAR':'Bu kadar','BUGUN':'Bugün','BUYUK':'Büyük',
    'CARSAMBA':'Çarşamba','CAY':'Çay','CD':'CD','CEP TELEFONU':'Cep telefonu',
    'CEZA':'Ceza','CIKOLATA':'Çikolata','CUMA':'Cuma','CUMARTESI':'Cumartesi',
    'CUNKU':'Çünkü','DIKKAT':'Dikkat','DOKTOR':'Doktor','DOKUZ':'Dokuz',
    'DORT':'Dört','DOYMAK':'Doymak','DUN':'Dün','EKIM':'Ekim','EKMEK':'Ekmek',
    'ELHAMDULILLAH':'Elhamdülillah','ERIK':'Erik','EV':'Ev','EVET':'Evet',
    'EVLENMEK':'Evlenmek','EYLUL':'Eylül','FINAL':'Final','FUTBOL':'Futbol',
    'GUN':'Gün','HANGI':'Hangi','HAZIRAN':'Haziran','HEMSIRE':'Hemşire',
    'HENTBOL':'Hentbol','HOSCA KAL':'Hoşça kal','IKI':'İki','IYI':'İyi',
    'KAHVE':'Kahve','KASIM':'Kasım','KIS':'Kış','KOTU':'Kötü','KUCUK':'Küçük',
    'MART':'Mart','MAYIS':'Mayıs','MERHABA':'Merhaba','NISAN':'Nisan',
    'OCAK':'Ocak','OGRETMEN':'Öğretmen','OKUL':'Okul','ORUC':'Oruç',
    'PAZAR':'Pazar','PAZARTESI':'Pazartesi','PERSEMBE':'Perşembe',
    'SABAH':'Sabah','SALI':'Salı','SEKIZ':'Sekiz','SEN':'Sen','SIFIR':'Sıfır',
    'SORU':'?','SU':'Su','SUBAT':'Şubat','TEMMUZ':'Temmuz','TESEKKUR':'Teşekkür',
    'TUVALET':'Tuvalet','TV':'TV','UC':'Üç','VOLEYBOL':'Voleybol',
    'YARDIM':'Yardım','YATMAK':'Yatmak','YEDI':'Yedi','YEMEK':'Yemek',
    'YETER':'Yeter','ZENGIN':'Zengin',
    // Yeni 22 kelime
    'NASILSIN':'nasılsın','NE':'ne','KAC':'kaç','NEREDE':'nerede',
    'YAPMAK':'yapmak','CALISMAK':'çalışmak','YORULMAK':'yorulmak',
    'BITMEK':'bitmek','ICMEK':'içmek','BULUSMAK':'buluşmak',
    'GORUSMEK':'görüşmek','BAKMAK':'bakmak',
    'COK':'çok','SAAT':'saat','SONRA':'sonra','BOS':'boş',
    'BERABER':'beraber','TAMAM':'tamam',
    'PARK':'park','YAN':'yan','KAFE':'kafe','KENDI':'kendi',
  };

  // Fiil cekim tablosu — ozneye gore (BEN/SEN/default)
  static const Map<String, Map<String, String>> verbConj = {
    'YAPMAK':   {'ben':'yapıyorum','sen':'yapıyorsun','_':'yapıyor'},
    'CALISMAK': {'ben':'çalışıyorum','sen':'çalışıyorsun','_':'çalışıyor'},
    'YORULMAK': {'ben':'yoruldum','sen':'yoruldun','_':'yoruldu'},
    'BITMEK':   {'ben':'bitiyor','sen':'bitiyor','_':'bitiyor'},
    'ICMEK':    {'ben':'içiyorum','sen':'içiyorsun','_':'içelim'},
    'BULUSMAK': {'ben':'buluşalım','sen':'buluşalım','_':'buluşalım'},
    'GORUSMEK': {'ben':'görüşürüz','sen':'görüşürüz','_':'görüşürüz'},
    'BAKMAK':   {'ben':'bakıyorum','sen':'bak','_':'bak'},
    'EVLENMEK': {'ben':'evleniyorum','sen':'evleniyorsun','_':'evleniyor'},
    'YATMAK':   {'ben':'yatıyorum','sen':'yatıyorsun','_':'yatıyor'},
    'DOYMAK':   {'ben':'doydum','sen':'doydun','_':'doydu'},
    'BOS VERMEK':{'ben':'boş veriyorum','sen':'boş ver','_':'boş ver'},
  };

  static const Map<String, String> phraseOverride = {
    'TESEKKUR': 'teşekkür ederim',
    'NASILSIN': 'nasılsın',
    'HOSCA KAL': 'hoşça kal',
    'KENDI': 'kendine',
    'BU KADAR': 'bu kadar',
    'CEP TELEFONU': 'cep telefonu',
    'AFERIN': 'aferin',
    'EVET': 'evet',
  };

  static const Set<String> commaAfter = {
    'TAMAM','EVET','HOSCA KAL','MERHABA','AFERIN'
  };

  static const Set<String> questionGloss = {
    'NE','KAC','NEREDE','HANGI','NASILSIN','SORU'
  };

  static const Map<String, String> numAblative = {
    'BIR':'birden','IKI':'ikiden','UC':'üçten','DORT':'dörtten',
    'BES':'beşten','ALTI':'altıdan','YEDI':'yediden','SEKIZ':'sekizden',
    'DOKUZ':'dokuzdan','ON':'ondan',
  };

  /// Turkce cumleyi gloss listesine cevir (avatar icin)
  static List<String> turkishToGloss(String sentence, List<String> knownWords) {
    final raw = sentence.trim();
    if (raw.isEmpty) return [];

    // Detect question
    final isQuestion = raw.contains('?') ||
        RegExp(r'\b(MI|MU|MÜ|Mİ|MISIN|MUSUN|MIDIR|MUDUR)\b', caseSensitive: false)
            .hasMatch(normTR(raw));

    // Clean and normalize
    String cleaned = normTR(raw)
        .replaceAll('?', '')
        .replaceAll(RegExp(r'\b(MI|MU|MISIN|MUSUN|MIDIR|MUDUR|MIYIZ|MUYUZ)\b'), '')
        .trim();

    final words = cleaned.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final result = <String>[];
    final knownSet = knownWords.toSet();

    // Build set of multi-word poses (e.g. "HOSCA KAL", "BOS VERMEK")
    final multiWordPoses = knownWords.where((k) => k.contains(' ')).toSet();

    int i = 0;
    while (i < words.length) {
      // Try multi-word match first (2-3 words)
      bool multiFound = false;
      for (int len = 3; len >= 2; len--) {
        if (i + len <= words.length) {
          final combined = words.sublist(i, i + len).join(' ');
          if (knownSet.contains(combined)) {
            result.add(combined);
            i += len;
            multiFound = true;
            break;
          }
        }
      }
      if (multiFound) continue;

      final word = words[i];
      i++;

      // Direct match
      if (knownSet.contains(word)) {
        result.add(word);
        continue;
      }

      // Try stripping suffixes
      bool found = false;
      String? stemmed;
      for (final suf in _suffixes) {
        if (word.length >= suf.length + 2 && word.endsWith(suf)) {
          final root = word.substring(0, word.length - suf.length);
          if (root.length >= 2) {
            stemmed = root;
            // 1) Direkt eslesme
            if (knownSet.contains(root)) {
              result.add(root);
              found = true;
              break;
            }
            // 2) Mastar formu: root + MAK / MEK
            if (knownSet.contains(root + 'MAK')) {
              result.add(root + 'MAK');
              found = true;
              break;
            }
            if (knownSet.contains(root + 'MEK')) {
              result.add(root + 'MEK');
              found = true;
              break;
            }
            break; // ilk strip sonrasi bulamadik, fuzzy'ye gec
          }
        }
      }

      if (!found) {
        // Mastar dogrudan dene: word + MAK / MEK
        if (knownSet.contains(word + 'MAK')) { result.add(word + 'MAK'); continue; }
        if (knownSet.contains(word + 'MEK')) { result.add(word + 'MEK'); continue; }

        // Fuzzy match: en kisa baslayan adayi sec (BAKLAVA degil BAKMAK)
        final searchWord = stemmed ?? word;
        String? best;
        int bestDelta = 1 << 30;
        for (final kw in knownWords) {
          if (kw.startsWith(searchWord) || searchWord.startsWith(kw)) {
            final delta = (kw.length - searchWord.length).abs();
            if (delta < bestDelta) { bestDelta = delta; best = kw; }
          }
        }
        if (best != null && best.length >= 2) result.add(best);
      }
    }

    // Add SORU if question detected
    if (isQuestion && knownSet.contains('SORU')) result.add('SORU');

    return result;
  }

  /// Gloss listesini akilli cekimli Turkce cumleye cevir
  static String glossToTurkish(List<String> glossesIn) {
    if (glossesIn.isEmpty) return '';

    // Tekrar sikistirma (YAPMAK YAPMAK -> YAPMAK)
    final glosses = <String>[];
    for (var i = 0; i < glossesIn.length; i++) {
      if (i == 0 || glossesIn[i] != glossesIn[i-1]) glosses.add(glossesIn[i]);
    }

    final hasBen = glosses.contains('BEN');
    final hasSen = glosses.contains('SEN');
    String? lastSubject;
    bool lastWasVerb = false;
    final out = <String>[];

    for (var i = 0; i < glosses.length; i++) {
      final w = glosses[i];
      final prev = i > 0 ? glosses[i-1] : null;
      final next = i < glosses.length - 1 ? glosses[i+1] : null;
      final next2 = i < glosses.length - 2 ? glosses[i+2] : null;

      // Sayi + SONRA -> "{sayi}-tan sonra"
      if (numAblative.containsKey(w) && next == 'SONRA') {
        out.add(numAblative[w]!);
        out.add('sonra');
        i++;
        lastWasVerb = false;
        continue;
      }

      // PARK + YAN + isim
      if (w == 'PARK' && next == 'YAN' && next2 != null && glossToTR.containsKey(next2)) {
        final nounTr = glossToTR[next2]!;
        out.add('parkın');
        out.add('yanındaki');
        out.add(_locative(nounTr));
        i += 2;
        lastWasVerb = false;
        continue;
      }
      if (w == 'YAN') { out.add('yanı'); lastWasVerb = false; continue; }

      if (w == 'BOS') {
        if (lastSubject == 'ben' || (hasBen && !hasSen)) out.add('boşum');
        else if (lastSubject == 'sen' || hasSen) out.add('boşsun');
        else out.add('boş');
        lastWasVerb = false; continue;
      }

      if (w == 'KAC' && prev == 'SAAT') { out.add('kaçta'); lastWasVerb = false; continue; }

      if (w == 'BEN') { lastSubject = 'ben'; out.add('ben'); lastWasVerb = false; continue; }
      if (w == 'SEN') { lastSubject = 'sen'; out.add('sen'); lastWasVerb = false; continue; }

      if (w == 'IYI') {
        if (lastSubject == 'ben' || (i == 0 && hasBen) || (i == 0 && !hasSen)) out.add('iyiyim');
        else if (lastSubject == 'sen' || (i == 0 && hasSen)) out.add('iyisin');
        else out.add('iyi');
        lastWasVerb = false; continue;
      }

      // Virgul-sonrasi sozler
      if (commaAfter.contains(w)) {
        final tr = (glossToTR[w] ?? w).toLowerCase();
        final tail = (i < glosses.length - 1) ? ',' : '';
        out.add(tr + tail);
        lastWasVerb = false;
        continue;
      }

      // Fiil cekimi
      if (verbConj.containsKey(w)) {
        final subj = lastSubject ?? '_';
        final form = verbConj[w]![subj] ?? verbConj[w]!['_']!;
        if (lastWasVerb && out.isNotEmpty) {
          out[out.length - 1] = '${out.last},';
        }
        out.add(form);
        lastWasVerb = true;
        continue;
      }

      // Ozel kalip
      if (phraseOverride.containsKey(w)) {
        out.add(phraseOverride[w]!);
        lastWasVerb = false;
        continue;
      }

      // SORU -> sona ? eklenir, kelime listesinde gozukmez
      if (w == 'SORU') continue;

      out.add((glossToTR[w] ?? w).toLowerCase());
      lastWasVerb = false;
    }

    String s = out.join(' ');
    s = s.replaceAll(RegExp(r'\s+([?!.,])'), r'$1');
    s = s.replaceAll(RegExp(r',\s*$'), '');
    if (s.isNotEmpty) s = s[0].toUpperCase() + s.substring(1);

    final hasQ = glosses.any(questionGloss.contains);
    if (hasQ) {
      if (!RegExp(r'[?!]$').hasMatch(s)) s += '?';
    } else {
      if (!RegExp(r'[.!?]$').hasMatch(s)) s += '.';
    }
    return s;
  }

  static String _locative(String word) {
    final last = word[word.length - 1].toLowerCase();
    final vowels = RegExp(r'[aeıioöuü]', caseSensitive: false).allMatches(word).toList();
    final lv = vowels.isEmpty ? 'a' : vowels.last.group(0)!.toLowerCase();
    final voiceless = 'çfhkpsşt'.contains(last);
    final front = 'eiöü'.contains(lv);
    return word + (voiceless ? 't' : 'd') + (front ? 'e' : 'a');
  }
}
