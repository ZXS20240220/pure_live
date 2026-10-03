import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/account/taobao/taobao_cookie_controller.dart';
import 'package:pure_live/modules/account/widgets/account_cookie_editor.dart';
import 'package:pure_live/modules/settings/settings_breadcrumb.dart';

class TaobaoCookiePage extends GetView<TaobaoCookieController> {
  const TaobaoCookiePage({super.key});

  @override
  Widget build(BuildContext context) => AccountCookieEditorPage(
    breadcrumb: SettingsCrumbs.taobaoCookie,
    controller: controller.cookieController,
    hintText: i18n('cookie_hint', args: {'name': i18n('site_taobaolive')}),
    tipText: i18n('cookie_tip', args: {'name': i18n('site_taobaolive')}),
    onSave: controller.setCookie,
  );
}
