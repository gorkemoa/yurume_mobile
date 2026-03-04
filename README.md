# Yurume Mobile (Flutter)

Bu uygulama Laravel backend ile gerçek zamanlı yürüyüş rotası kaydeder ve oluşan alanları harita üzerinde kalıcı gösterir.

## Özellikler

- Kullanıcı kayıt/giriş (Sanctum token)
- Canlı konum takibi (gerçek GPS)
- `Başlat` / `Bitir` rota akışı
- Rota polyline çizimi
- Backend tarafından üretilen kapalı alanların (polygon/triangle) kalıcı gösterimi
- Ücretsiz harita katmanı: OpenStreetMap
- API URL ve cihaz adı ayarı
- Otomatik yerel ağ backend bulma (`Ağda Bul`)
- Tek tuş demo giriş

## Kurulum

```bash
cd /Users/admin/Documents/yurume/yurume_mobile
flutter pub get
flutter run
```

## Backend URL Notu

Varsayılanlar:

- Android emulator: `http://10.0.2.2:8000/api`
- iOS simulator / macOS: `http://127.0.0.1:8000/api`

Fiziksel cihazda, backend’in cihazdan erişilebilir bir IP/domain üzerinde olması gerekir. URL uygulama içi Ayarlar ekranından değiştirilebilir.

## İzinler

- Android: `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`, `INTERNET`
- iOS: `NSLocationWhenInUseUsageDescription` vb. konum açıklamaları

## Akış

1. API URL gir ve giriş/kayıt ol.
   - İstersen `Ağda Bul` butonuyla backend otomatik bulunur.
   - `Demo Hesap ile Giriş` butonu hazır hesapla hızlı giriş yapar.
2. Haritada mevcut konumunu gör.
3. `Başlat` ile rota kaydını aç.
4. Yürürken rota çizilir ve noktalar backend’e batch olarak gönderilir.
5. `Bitir` ile alan oluşturulur; başarılı alanlar kalıcı territory olarak haritada görünür.
6. Kullanıcı vazgeçerse `Vazgeç (alan kaydetme)` ile sadece oturum kapatılır.
