import 'dart:async';

import 'package:collection/collection.dart';
import 'package:ds_ads/ds_ads.dart';
import 'package:ds_ads/src/applovin_ads/ds_applovin_ad_widget.dart';
import 'package:ds_ads/src/applovin_ads/ds_applovin_native_ad.dart';
import 'package:fimber/fimber.dart';
import 'package:flutter/material.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'google_ads/export.dart';

part 'ds_ads_native_loader_types.dart';


mixin DSAdsNativeLoaderMixin<T extends StatefulWidget> on State<T> {
  final _adKey = GlobalKey();
  bool get isShowed => _showedAds[this] != null;

  DSAdLocation get nativeAdLocation;

  static final _loadingAds = <DSNativeStyle, DSNativeAd>{};
  static final _showedAds = <DSAdsNativeLoaderMixin, DSNativeAd>{};

  /// Реклама уже предзагружена или сейчас загружается
  static bool hasPreloadedAd(DSAdLocation location) {
    final style = _getStyleByLocation(location);
    return _loadingAds.containsKey(style);
  }

  static String get adUnitId {
    final mediation = DSAdsManager.instance.currentMediation;
    if (mediation == null) {
      return 'noMediation';
    }
    switch (mediation) {
      case DSAdMediation.google:
        return DSAdsManager.instance.nativeGoogleUnitId!;
      case DSAdMediation.yandex:
        throw UnimplementedError();
      case DSAdMediation.appLovin:
        return DSAdsManager.instance.nativeAppLovinUnitId!;
    }
  }

  double get nativeAdHeight {
    var height = DSAdsManager.instance.nativeAdCustomBanners.firstWhereOrNull((e) => e.location == nativeAdLocation)?.height;
    if (height != null) return height;
    // the same as in res/layout/native_ad_X_light.xml and res/layout/native_ad_X_dark.xml
    switch (DSAdsManager.instance.nativeAdBannerDefStyle) {
      case DSNativeAdBannerStyle.style1:
        return 260;
      case DSNativeAdBannerStyle.style2:
        return 280;
      default:
        assert(false, 'nativeAdBannerDefStyle or nativeAdCustomBanners should be defined');
        return 0;
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(() async {
      await for (final event in DSAdsManager.instance.eventStream) {
        if (!mounted) return;
        if (event is DSAdsNativeLoadedEvent) {
          final res = _assignAdToMe();
          if (res) {
            setState(() {});
          }
        }
      }
    } ());
    _isDisabled(nativeAdLocation);
    unawaited(fetchAd(location: nativeAdLocation));
    _assignAdToMe();
  }

  @override
  void dispose() {
    final ad = _showedAds[this];
    _report('ads_native: dispose (isShowed: ${ad != null})', location: nativeAdLocation);
    ad?.dispose();
    unawaited(fetchAd(location: const DSAdLocation('internal_dispose')));
    super.dispose();
  }

  @internal
  static Future<void> disposeClass() async {
    while (_loadingAds.isNotEmpty) {
      await _loadingAds.remove(_loadingAds.keys.first)?.dispose();
    }
  }

  static Future<void> _disposeOtherMediation() async {
    final Type currentClass;
    switch (DSAdsManager.instance.currentMediation) {
      case DSAdMediation.google:
        currentClass = DSGoogleNativeAd;
        break;
      case DSAdMediation.yandex:
        throw UnimplementedError();
      case DSAdMediation.appLovin:
        currentClass = DSAppLovinNativeAd;
        break;
      default:
        throw UnimplementedError();
    }
    _loadingAds.removeWhere((key, value) {
      final del = value.runtimeType != currentClass;
      if (del) {
        unawaited(value.dispose());
      }
      return del;
    });
    _showedAds.removeWhere((key, value) {
      final del = value.runtimeType != currentClass;
      if (del) {
        value.dispose();
      }
      return del;
    });
  }

  static void _report(String eventName, {
    required final DSAdLocation location,
    Map<String, Object>? attributes,
  }) {
    DSAdsManager.instance.onReportEvent?.call(eventName, {
      'location': location.val,
      'adUnitId': adUnitId,
      'mediation': '${DSAdsManager.instance.currentMediation}',
      ...?attributes,
    });
  }

  static DSAdLocation _getLocationByAd(DSNativeAd ad) {
    final obj = _showedAds.entries.firstWhereOrNull((e) => e.value == ad)?.key;
    return obj?.nativeAdLocation ?? const DSAdLocation('internal_unassigned');
  }

  static DSNativeStyle _getStyleByLocation(DSAdLocation location) {
    String? style;
    if (!location.isInternal) {
      style = DSAdsManager.instance.nativeAdCustomBanners.firstWhereOrNull((e) => e.location == location)?.style;
    }
    style ??= DSAdsManager.instance.nativeAdBannerDefStyle;
    return style;
  }

  static String _getFactoryId({
    required final DSAdLocation location,
  }) {
    final style = _getStyleByLocation(location);
    switch (DSAdsManager.instance.appState.brightness) {
      case Brightness.light:
        return '${style}Light';
      case Brightness.dark:
        return '${style}Dark';
    }
  }

  static final _locationErrReports = <DSAdLocation>{};

  static bool _isDisabled(DSAdLocation location) {
    if (!location.isInternal && DSAdsManager.instance.locations?.contains(location) == false) {
      final msg = 'ads_native: location $location not in locations';
      assert(false, msg);
      if (!_locationErrReports.contains(location)) {
        _locationErrReports.add(location);
        Fimber.e(msg, stacktrace: StackTrace.current);
      }
    }
    if (DSAdsManager.instance.isAdAllowedCallback?.call(DSAdSource.native, location) == false) {
      Fimber.i('ads_native: disabled (location: $location)');
      return true;
    }
    if (DSAdsManager.instance.currentMediation == DSAdMediation.yandex) {
      Fimber.i('ads_native: disabled (no mediation)');
      return true;
    }
    return false;
  }

  static Future<void> fetchAd({
    required final DSAdLocation location,
  }) async {
    await DSAdsManager.instance.checkMediation();

    if (_isDisabled(location)) return;

    await _disposeOtherMediation();

    final style = _getStyleByLocation(location);
    if (_loadingAds[style] != null) {
      Fimber.i('ads_native: banner already loaded (location: $location)');
      return;
    }
    if (_loadingAds.containsKey(style)) {
      Fimber.i('ads_native: banner is already loading (location: $location)');
      return;
    }
    final factoryId = _getFactoryId(location: location);
    if (style.isEmpty) {
      assert(location.isInternal, 'DSAdsManager.instance.nativeAd... should be defined');
      return;
    }

    final mediation = DSAdsManager.instance.currentMediation!;

    Future<void> onAdImpression(DSNativeAd ad) async {
      try {
        _report('ads_native: impression', location: location);
      } catch (e, stack) {
        Fimber.e('$e', stacktrace: stack);
      }
    };
    Future<void> onAdLoaded(DSNativeAd ad) async {
      try {
        _loadingAds[style] = ad;
        _report('ads_native: loaded', location: location);
        DSAdsManager.instance.emitEvent(DSAdsNativeLoadedEvent._(ad: ad));
      } catch (e, stack) {
        Fimber.e('$e', stacktrace: stack);
      }
    };
    Future<void> onAdFailedToLoad(DSNativeAd ad, int code, String message) async {
      try {
        _loadingAds.remove(style);
        _report('ads_native: failed to load', location: location, attributes: {
          'error_text': message,
          'error_code': '$code ($mediation)',
        });
        DSAdsManager.instance.emitEvent(const DSAdsNativeLoadFailed._());
        await ad.dispose();
        await DSAdsManager.instance.onLoadAdError.call(code, message, mediation, DSAdSource.native);
      } catch (e, stack) {
        Fimber.e('$e', stacktrace: stack);
      }
    };
    Future<void> onPaidEvent(DSNativeAd ad, double valueMicros, DSPrecisionType precision, String currencyCode) async {
      try {
        DSAdsManager.instance.onPaidEvent(ad, mediation, location, valueMicros, precision, currencyCode, DSAdSource.native, null);
      } catch (e, stack) {
        Fimber.e('$e', stacktrace: stack);
      }
    };
    Future<void> onAdOpened(DSNativeAd ad) async {
      try {
        _report('ads_native: ad opened', location: _getLocationByAd(ad));
      } catch (e, stack) {
        Fimber.e('$e', stacktrace: stack);
      }
    };
    Future<void> onAdClicked(DSNativeAd ad) async {
      try {
        _report('ads_native: ad clicked', location: _getLocationByAd(ad));
      } catch (e, stack) {
        Fimber.e('$e', stacktrace: stack);
      }
    };
    Future<void> onAdClosed(DSNativeAd ad) async {
      try {
        _report('ads_native: ad closed', location: _getLocationByAd(ad));
      } catch (e, stack) {
        Fimber.e('$e', stacktrace: stack);
      }
    };
    Future<void> onAdExpired(DSNativeAd ad) async {
      try {
        _report('ads_native: ad expired', location: _getLocationByAd(ad));
      } catch (e, stack) {
        Fimber.e('$e', stacktrace: stack);
      }
    };

    final DSNativeAd nativeAd;
    switch (mediation) {
      case DSAdMediation.google:
        nativeAd = DSGoogleNativeAd(
          adUnitId: adUnitId,
          factoryId: factoryId,
          onPaidEvent: onPaidEvent,
          onAdImpression: onAdImpression,
          onAdClicked: onAdClicked,
          onAdClosed: onAdClosed,
          onAdOpened: onAdOpened,
          onAdLoaded: onAdLoaded,
          onAdFailedToLoad: onAdFailedToLoad,
        );
        break;
      case DSAdMediation.yandex:
        throw UnimplementedError();
      case DSAdMediation.appLovin:
        nativeAd = DSAppLovinNativeAd(
          adUnitId: adUnitId,
          factoryId: factoryId,
          onPaidEvent: onPaidEvent,
          onAdClicked: onAdClicked,
          onAdLoaded: onAdLoaded,
          onAdFailedToLoad: onAdFailedToLoad,
          onAdExpired: onAdExpired,
        );
        break;
    }
    _loadingAds[style] = nativeAd;
    _report('ads_native: start loading', location: location);
    await nativeAd.load();
  }

  bool _assignAdToMe() {
    if (isShowed) return false;
    final style = _getStyleByLocation(nativeAdLocation);
    final readyAd = _loadingAds[style];
    if (readyAd == null || !readyAd.isLoaded) return false;
    _showedAds[this] = readyAd;
    _loadingAds.remove(style);
    return true;
  }

  Widget nativeAdWidget({
    final NativeAdBuilder? builder,
  }) {
    assert(!nativeAdLocation.isInternal);
    if (!DSAdsManager.instance.isAdAvailable) return const SizedBox();
    if (DSAdsManager.instance.appState.isPremium) return const SizedBox();
    if (_isDisabled(nativeAdLocation)) return const SizedBox();

    Widget child;
    final ad = _showedAds[this];
    if (ad == null) {
      child = const Center(child: CircularProgressIndicator());
    } else if (ad is DSGoogleNativeAd) {
      child = DSGoogleAdWidget(key: _adKey, ad: ad);
    } else if (ad is DSAppLovinNativeAd) {
      child = DSAppLovinAdWidget(ad: ad);
    } else {
      throw UnimplementedError();
    }

    child = SizedBox(
      height: nativeAdHeight,
      child: child,
    );
    if (builder != null) {
      return builder(context, isShowed, child);
    } else {
      return child;
    }
  }

}