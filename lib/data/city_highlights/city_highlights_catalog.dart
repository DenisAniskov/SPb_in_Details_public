import 'package:smart_navigator_spb/data/city_highlights/city_highlight_model.dart';
import 'package:smart_navigator_spb/data/models/place_model.dart';

/// C14 editorial catalog, bundled with the client.
///
/// Why local and not a backend endpoint: the card set is small, keyed by the
/// immutable catalog key and contains no user-specific state. Keeping it in
/// the app means C14 works with the already deployed catalog without a new
/// API, migration or network failure mode. The source list stays in the data
/// so a later backend move would be a mechanical change.
///
/// Only places that already exist in the catalog are included. A missing card
/// is a valid state: the place screen then shows nothing from C14.
abstract final class CityHighlightsCatalog {
  static const String _verifiedOn = '2026-10-18';

  static const List<CityHighlight> entries = [
    CityHighlight(
      catalogKey: 'hermitage-winter-palace',
      attentionHints: [
        'Посмотрите на крышу вдоль фасада: балюстраду завершают статуи и вазы. Они продолжают вертикальный ритм колонн и делают силуэт дворца легче.',
        'Найдите тройную арку в центре южного фасада: через неё главный вход с Дворцовой площади ведёт во внутренний двор.',
        'Пройдите вдоль Невы и оцените длину фасада — 210 метров одного архитектурного ритма.',
      ],
      shortStory: 'Зимний дворец строился для императрицы Елизаветы Петровны, но она не дожила до окончания работ. В апреле 1762 года работу принимал уже Пётр III, а отделку завершали при Екатерине II. Растрелли императрица отстранила, и внутренние залы доделывали другие архитекторы. Поэтому снаружи дворец остаётся единым замыслом Растрелли, а внутри — наслоением нескольких эпох.',
      viewpoint: CityViewpoint(
        name: 'Дворцовый мост',
        description: 'С Дворцового моста дворец виден вдоль Невы: в кадр попадают фасад, набережная и отражение в воде. Это общедоступный тротуар моста.',
        latitude: 59.9410186,
        longitude: 30.3087045,
        sourceUrl: 'https://www.openstreetmap.org/node/4271175480',
        verifiedOn: _verifiedOn,
      ),
      sources: [
        CityHighlightSource(
          title: 'Зимний дворец на сайте Государственного Эрмитажа',
          url: 'https://www.hermitagemuseum.org/wps/portal/hermitage/explore/buildings/locations/building/B10/',
          sourceType: 'official',
        ),
        CityHighlightSource(
          title: 'Зимний дворец — Википедия',
          url: 'https://ru.wikipedia.org/wiki/%D0%97%D0%B8%D0%BC%D0%BD%D0%B8%D0%B9_%D0%B4%D0%B2%D0%BE%D1%80%D0%B5%D1%86',
          sourceType: 'encyclopedia',
        ),
        CityHighlightSource(
          title: 'Вид с Дворцового моста на Зимний дворец — OpenStreetMap',
          url: 'https://www.openstreetmap.org/node/4271175480',
          sourceType: 'map',
        ),
      ],
      verifiedOn: _verifiedOn,
    ),
    CityHighlight(
      catalogKey: 'saint-isaacs-cathedral',
      attentionHints: [
        'Подойдите к портику и рассмотрите гранитные колонны: каждая выточена из цельного монолита.',
        'Найдите бронзовые горельефы на фронтонах: у северного, южного, восточного и западного портиков разные сюжеты.',
        'Обойдите собор вокруг: с каждой стороны свой портик и свои скульптурные группы наверху.',
      ],
      shortStory: 'Нынешний Исаакий — уже четвёртый собор с этим именем. Первый был деревянным и стоял у Адмиралтейства: в 1712 году в нём венчались Пётр I и Екатерина Алексеевна. Второй собор построили в камне, но он страдал от слабого грунта у Невы; третий так и не достроили. Монферран начал четвёртый в 1818 году и вёл строительство сорок лет. Собор освятили в 1858-м — и меньше чем через месяц архитектор умер.',
      viewpoint: CityViewpoint(
        name: 'Исаакиевская площадь',
        description: 'С Исаакиевской площади собор открывается целиком: портики, барабан и золочёный купол. Отойдите к памятнику Николаю I, чтобы увидеть собор в перспективе площади.',
        latitude: 59.9328978,
        longitude: 30.3074375,
        sourceUrl: 'https://www.openstreetmap.org/way/638328792',
        verifiedOn: _verifiedOn,
      ),
      sources: [
        CityHighlightSource(
          title: 'История возведения Исаакиевского собора',
          url: 'https://www.cathedral.ru/ru/isaac/building',
          sourceType: 'official',
        ),
        CityHighlightSource(
          title: 'Наружная скульптура Исаакиевского собора',
          url: 'https://cathedral.ru/ru/isaac/outersculpture',
          sourceType: 'official',
        ),
        CityHighlightSource(
          title: 'Исаакиевский собор — Википедия',
          url: 'https://ru.wikipedia.org/wiki/%D0%98%D1%81%D0%B0%D0%B0%D0%BA%D0%B8%D0%B5%D0%B2%D1%81%D0%BA%D0%B8%D0%B9_%D1%81%D0%BE%D0%B1%D0%BE%D1%80',
          sourceType: 'encyclopedia',
        ),
        CityHighlightSource(
          title: 'Исаакиевская площадь — OpenStreetMap',
          url: 'https://www.openstreetmap.org/way/638328792',
          sourceType: 'map',
        ),
      ],
      verifiedOn: _verifiedOn,
    ),
    CityHighlight(
      catalogKey: 'savior-on-spilled-blood',
      attentionHints: [
        'Посмотрите на западный фасад под главным куполом: там выложены мозаичные гербы губерний, областей и городов Российской империи.',
        'Найдите на фасаде гранитные плиты с событиями биографии Александра II — они читаются как каменная летопись.',
        'Сравните купола и кокошники с московским Покровом на Рву: храм решён в русском стиле XVII века.',
      ],
      shortStory: 'Спас на Крови строили 24 года и освятили только в 1907-м. В 1930-х храм собирались разобрать, но война изменила планы: в блокаду здесь размещался морг, а после войны — склад декораций Малого оперного театра. В 1961 году в куполе нашли неразорвавшийся немецкий снаряд: он пролежал в стропилах 18 лет. Только в 1971 году здание передали музею, и началась долгая реставрация.',
      viewpoint: CityViewpoint(
        name: 'Набережная канала Грибоедова',
        description: 'С противоположного берега канала храм виден целиком: пять куполов, мозаичные детали фасада и отражение в воде.',
        latitude: 59.9392149,
        longitude: 30.3281051,
        sourceUrl: 'https://www.openstreetmap.org/node/13139990442',
        verifiedOn: _verifiedOn,
      ),
      sources: [
        CityHighlightSource(
          title: 'История создания Спаса на Крови',
          url: 'https://www.cathedral.ru/ru/spas/building',
          sourceType: 'official',
        ),
        CityHighlightSource(
          title: 'Храм Спаса на Крови — Википедия',
          url: 'https://ru.wikipedia.org/wiki/%D0%A5%D1%80%D0%B0%D0%BC_%D0%A1%D0%BF%D0%B0%D1%81%D0%B0_%D0%BD%D0%B0_%D0%9A%D1%80%D0%BE%D0%B2%D0%B8',
          sourceType: 'encyclopedia',
        ),
        CityHighlightSource(
          title: 'Точка обзора на набережной канала Грибоедова — OpenStreetMap',
          url: 'https://www.openstreetmap.org/node/13139990442',
          sourceType: 'map',
        ),
      ],
      verifiedOn: _verifiedOn,
    ),
    CityHighlight(
      catalogKey: 'peter-paul-fortress',
      attentionHints: [
        'С Иоанновского моста найдите ангела с крестом на вершине шпиля — отсюда видна вся вертикаль колокольни.',
        'Рассмотрите Петровские ворота: в нишах по сторонам арки стоят фигуры Минервы и Беллоны.',
        'Пройдите вдоль бастионов и обратите внимание на их имена — Меншиков, Нарышкин, Трубецкой, Головкин, Зотов.',
      ],
      shortStory: 'Петропавловский собор выше всех построек крепости: его колокольня со шпилем — 122,5 метра. Пётр I умер в 1725 году, когда собор ещё достраивался; его гроб поставили во временную часовню, а в 1731 году перезахоронили у иконостаса. С тех пор собор стал усыпальницей дома Романовых: здесь похоронены почти все российские императоры и императрицы XVIII — начала XX века.',
      viewpoint: CityViewpoint(
        name: 'Кронверкская набережная',
        description: 'С Кронверкской набережной крепость видна через Кронверкский пролив: читаются бастионы, Петровские ворота и шпиль собора.',
        latitude: 59.952616,
        longitude: 30.3147563,
        sourceUrl: 'https://www.openstreetmap.org/node/1509196359',
        verifiedOn: _verifiedOn,
      ),
      sources: [
        CityHighlightSource(
          title: 'Петропавловская крепость — исторический очерк',
          url: 'https://www.spbmuseum.ru/themuseum/museum_complex/peterpaul_fortress/ppk.php',
          sourceType: 'official',
        ),
        CityHighlightSource(
          title: 'Петропавловская крепость — Википедия',
          url: 'https://ru.wikipedia.org/wiki/%D0%9F%D0%B5%D1%82%D1%80%D0%BE%D0%BF%D0%B0%D0%B2%D0%BB%D0%BE%D0%B2%D1%81%D0%BA%D0%B0%D1%8F_%D0%BA%D1%80%D0%B5%D0%BF%D0%BE%D1%81%D1%82%D1%8C',
          sourceType: 'encyclopedia',
        ),
        CityHighlightSource(
          title: 'Точка обзора на Кронверкской набережной — OpenStreetMap',
          url: 'https://www.openstreetmap.org/node/1509196359',
          sourceType: 'map',
        ),
      ],
      verifiedOn: _verifiedOn,
    ),
    CityHighlight(
      catalogKey: 'singer-house',
      attentionHints: [
        'Поднимите взгляд к угловой башне: стеклянный глобус опоясан металлической лентой с золотой надписью «Зингер».',
        'Найдите на фасаде скульптуры-валькирии: у одной в руках миниатюрная швейная машинка.',
        'Сравните силуэт башни с шатрами Спаса на Крови — они стилистически перекликаются.',
      ],
      shortStory: 'Дом Зингера задумывали как витрину американской компании швейных машин. В Петербурге действовало ограничение высоты — не выше Зимнего дворца, 23,47 метра, — поэтому вместо восьми этажей Сюзор построил шесть и увёл силуэт в угловую башню. Стеклянный глобус с золотой лентой и скульптуры-валькирии напоминали о всемирной торговле. Сегодня здесь по-прежнему работает Дом книги.',
      sources: [
        CityHighlightSource(
          title: 'Дом компании «Зингер» — Википедия',
          url: 'https://ru.wikipedia.org/wiki/%D0%94%D0%BE%D0%BC_%D0%BA%D0%BE%D0%BC%D0%BF%D0%B0%D0%BD%D0%B8%D0%B8_%C2%AB%D0%97%D0%B8%D0%BD%D0%B3%D0%B5%D1%80%C2%BB',
          sourceType: 'encyclopedia',
        ),
        CityHighlightSource(
          title: 'История одного здания: Дом Зингер — Ведомости',
          url: 'https://www.vedomosti.ru/gorod/culturalcity/articles/dom-zingera',
          sourceType: 'publication',
        ),
      ],
      verifiedOn: _verifiedOn,
    ),
    CityHighlight(
      catalogKey: 'russian-museum',
      attentionHints: [
        'Посмотрите на главный фасад с Инженерной улицы: восемь коринфских колонн портика подняты на рустованную аркаду.',
        'Пройдите в Михайловский сад и найдите садовый фасад с просторной колонной лоджией — он выглядит иначе, чем парадный.',
        'Найдите на фасаде скульптурный фриз из 44 барельефов — он тянется вдоль боковых корпусов.',
      ],
      shortStory: 'Михайловский дворец Росси строил для великого князя Михаила Павловича, младшего брата Николая I. После смерти владельцев его внуки продали дворец в казну, и в 1895 году Николай II учредил здесь «Русский музей императора Александра III». Интерьеры перестроили под музейные залы, а первый в России государственный музей русского искусства открылся в 1898 году. Дворец остался дворцом — но его парадные залы стали выставочными.',
      viewpoint: CityViewpoint(
        name: 'Михайловский сад',
        description: 'Из Михайловского сада дворец открывается садовым фасадом с колонной лоджией — ракурс, которого не видно с Инженерной улицы.',
        latitude: 59.9398165,
        longitude: 30.332886,
        sourceUrl: 'https://www.openstreetmap.org/relation/2614476',
        verifiedOn: _verifiedOn,
      ),
      sources: [
        CityHighlightSource(
          title: 'О Русском музее',
          url: 'https://rusmuseum.ru/about/',
          sourceType: 'official',
        ),
        CityHighlightSource(
          title: 'Михайловский дворец — Википедия',
          url: 'https://ru.wikipedia.org/wiki/%D0%9C%D0%B8%D1%85%D0%B0%D0%B9%D0%BB%D0%BE%D0%B2%D1%81%D0%BA%D0%B8%D0%B9_%D0%B4%D0%B2%D0%BE%D1%80%D0%B5%D1%86',
          sourceType: 'encyclopedia',
        ),
        CityHighlightSource(
          title: 'Михайловский сад — OpenStreetMap',
          url: 'https://www.openstreetmap.org/relation/2614476',
          sourceType: 'map',
        ),
      ],
      verifiedOn: _verifiedOn,
    ),
    CityHighlight(
      catalogKey: 'mariinsky-theatre',
      attentionHints: [
        'Посмотрите на фасад с Театральной площади: при перестройке Шрётера два верхних этажа объединили четыре полуколонны.',
        'Найдите над окнами лепные маски и изображения лир — музыкальные мотивы в декоре.',
        'Обойдите театр к Крюкову каналу: с набережной видно, как здание примыкает к воде.',
      ],
      shortStory: 'Мариинский театр вырос на месте сгоревшего цирка. Кавос не стал искать новый участок: он поставил театр на уцелевший фундамент и уже в 1860 году открыл сезон оперой Глинки «Жизнь за царя». Театр назвали в честь императрицы Марии Александровны. В 1883–1886 годах здание перестроил Виктор Шрётер, и театр получил тот парадный фасад, который мы видим сегодня.',
      viewpoint: CityViewpoint(
        name: 'Театральная площадь',
        description: 'С Театральной площади виден главный фасад театра целиком; отсюда хорошо читаются его симметрия и ярусные пилястры.',
        latitude: 59.9260661,
        longitude: 30.2981143,
        sourceUrl: 'https://www.openstreetmap.org/way/638338375',
        verifiedOn: _verifiedOn,
      ),
      sources: [
        CityHighlightSource(
          title: 'История Мариинского театра',
          url: 'https://www.mariinsky.ru/about/history/mariinsky_theatre/',
          sourceType: 'official',
        ),
        CityHighlightSource(
          title: 'Мариинский театр — Википедия',
          url: 'https://ru.wikipedia.org/wiki/%D0%9C%D0%B0%D1%80%D0%B8%D0%B8%D0%BD%D1%81%D0%BA%D0%B8%D0%B9_%D1%82%D0%B5%D0%B0%D1%82%D1%80',
          sourceType: 'encyclopedia',
        ),
        CityHighlightSource(
          title: 'Здание Мариинского театра — Википедия',
          url: 'https://ru.wikipedia.org/wiki/%D0%97%D0%B4%D0%B0%D0%BD%D0%B8%D0%B5_%D0%9C%D0%B0%D1%80%D0%B8%D0%B8%D0%BD%D1%81%D0%BA%D0%BE%D0%B3%D0%BE_%D1%82%D0%B5%D0%B0%D1%82%D1%80%D0%B0',
          sourceType: 'encyclopedia',
        ),
        CityHighlightSource(
          title: 'Театральная площадь — OpenStreetMap',
          url: 'https://www.openstreetmap.org/way/638338375',
          sourceType: 'map',
        ),
      ],
      verifiedOn: _verifiedOn,
    ),
    CityHighlight(
      catalogKey: 'new-holland',
      attentionHints: [
        'Подойдите к арке: она перекинута через канал, соединяющий внутренний ковш с Мойкой, и сложена из красного кирпича без штукатурки.',
        'Посмотрите на склады: их фасады решены аркадой из полукруглых проёмов.',
        'Найдите круглое здание «Бутылку» — бывшую морскую тюрьму.',
      ],
      shortStory: 'Новая Голландия появилась на карте в 1719 году, когда для складов Адмиралтейства прорыли два канала. Корабельный лес здесь сушили вертикально, «по-голландски», — отсюда и название. Краснокирпичные склады и арку над каналом строили во второй половине XVIII века. Остров почти три века оставался закрытой территорией: сначала военные склады, потом база флота. После реставрации его открыли для горожан.',
      viewpoint: CityViewpoint(
        name: 'Набережная Адмиралтейского канала',
        description: 'С набережной Адмиралтейского канала арка Новой Голландии видна с воды: лучше читаются её пролёт, колонны и кирпичная кладка.',
        latitude: 59.9279399,
        longitude: 30.2904266,
        sourceUrl: 'https://www.openstreetmap.org/node/3768499136',
        verifiedOn: _verifiedOn,
      ),
      sources: [
        CityHighlightSource(
          title: 'История Новой Голландии: XVIII век',
          url: 'https://www.newhollandsp.ru/history/xviii-century/',
          sourceType: 'official',
        ),
        CityHighlightSource(
          title: 'Новая Голландия (остров) — Википедия',
          url: 'https://ru.wikipedia.org/wiki/%D0%9D%D0%BE%D0%B2%D0%B0%D1%8F_%D0%93%D0%BE%D0%BB%D0%BB%D0%B0%D0%BD%D0%B4%D0%B8%D1%8F_%28%D0%BE%D1%81%D1%82%D1%80%D0%BE%D0%B2%29',
          sourceType: 'encyclopedia',
        ),
        CityHighlightSource(
          title: 'Арка Новой Голландии — OpenStreetMap',
          url: 'https://www.openstreetmap.org/node/3768499136',
          sourceType: 'map',
        ),
      ],
      verifiedOn: _verifiedOn,
    ),
    CityHighlight(
      catalogKey: 'kazan-cathedral',
      attentionHints: [
        'Пройдите вдоль колоннады: 96 колонн из пудожского травертина стоят в четыре ряда.',
        'Найдите перед собором памятники Кутузову и Барклаю-де-Толли.',
        'Обратите внимание, что колоннада только одна: вторую, симметричную, так и не построили.',
      ],
      shortStory: 'Казанский собор строился всего десять лет, но задумывался как главный храм империи. Воронихин поставил колоннаду не сзади, а со стороны Невского проспекта — собор раскрылся на главную улицу города. После 1812 года здесь похоронили Кутузова и выставили трофейные знамёна. В 1932 году храм превратили в Музей истории религии и атеизма, а богослужения вернулись только в 1991-м.',
      sources: [
        CityHighlightSource(
          title: 'Казанский кафедральный собор — официальный туристический портал Санкт-Петербурга',
          url: 'https://visit-petersburg.ru/leisure/places/kazanskiy-kafedralnyy-sobor/',
          sourceType: 'official',
        ),
        CityHighlightSource(
          title:
              'Казанский собор — Президентская библиотека имени Б. Н. Ельцина',
          url: 'https://www.prlib.ru/news/1901860',
          sourceType: 'official',
        ),
        CityHighlightSource(
          title: 'Казанский собор — Википедия',
          url: 'https://ru.wikipedia.org/wiki/%D0%9A%D0%B0%D0%B7%D0%B0%D0%BD%D1%81%D0%BA%D0%B8%D0%B9_%D1%81%D0%BE%D0%B1%D0%BE%D1%80_%28%D0%A1%D0%B0%D0%BD%D0%BA%D1%82-%D0%9F%D0%B5%D1%82%D0%B5%D1%80%D0%B1%D1%83%D1%80%D0%B3%29',
          sourceType: 'encyclopedia',
        ),
      ],
      verifiedOn: _verifiedOn,
    ),
    CityHighlight(
      catalogKey: 'kunstkamera',
      attentionHints: [
        'Поднимите взгляд на башню: её венчает армиллярная сфера — напоминание об обсерватории, которая здесь была.',
        'Рассмотрите фасад петровского барокко: симметричные крылья и двухъярусная башня.',
      ],
      shortStory: 'Кунсткамера основана Петром I в 1714 году как первый публичный музей России. Для коллекции редкостей в 1718–1734 годах построили здание с башней и обсерваторией; в башне разместили Готторпский глобус, в залах — анатомические препараты и этнографические находки. Здесь работал Михаил Ломоносов. Сегодня это Музей антропологии и этнографии имени Петра Великого.',
      viewpoint: CityViewpoint(
        name: 'Стрелка Васильевского острова',
        description: 'Со Стрелки Васильевского острова Кунсткамера видна в перспективе Университетской набережной; отсюда хорошо читается её башня с армиллярной сферой.',
        latitude: 59.9442876,
        longitude: 30.3072541,
        sourceUrl: 'https://www.openstreetmap.org/node/669936547',
        verifiedOn: _verifiedOn,
      ),
      sources: [
        CityHighlightSource(
          title: 'Летопись Кунсткамеры. 1714–1836 гг.',
          url: 'https://cyberleninka.ru/article/n/letopis-kunstkamery-1714-1836-gg',
          sourceType: 'academic',
        ),
        CityHighlightSource(
          title: 'Кунсткамера — Википедия',
          url: 'https://ru.wikipedia.org/wiki/%D0%9A%D1%83%D0%BD%D1%81%D1%82%D0%BA%D0%B0%D0%BC%D0%B5%D1%80%D0%B0',
          sourceType: 'encyclopedia',
        ),
        CityHighlightSource(
          title: 'Стрелка Васильевского острова — OpenStreetMap',
          url: 'https://www.openstreetmap.org/node/669936547',
          sourceType: 'map',
        ),
      ],
      verifiedOn: _verifiedOn,
    ),
  ];

  static final Map<String, CityHighlight> _byKey = {
    for (final entry in entries) entry.catalogKey: entry,
  };

  static CityHighlight? forCatalogKey(String? catalogKey) {
    if (catalogKey == null || catalogKey.isEmpty) return null;
    return _byKey[catalogKey];
  }

  static CityHighlight? forPlace(PlaceModel place) =>
      forCatalogKey(place.catalogKey);
}
