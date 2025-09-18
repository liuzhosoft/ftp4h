import { FtpUser } from "../model/FtpUser";
import AppDimens from "../ui/AppDimens";

@Entry
@ComponentV2
struct Index {
  valueWeight = 6;
  labelWeight = 2;
  @Local address: string = "";
  @Local port: number = 21;
  @Local isAnonymous: boolean = false;
  @Local account: string = "";
  @Local password: string = "";
  readonly navStack = new NavPathStack();

  @Styles
  labelStyle() {
    .layoutWeight(this.labelWeight)
    .padding({ right: 2 });
  }

  @Styles
  inputStyle() {
    .layoutWeight(this.valueWeight);
  }

  build() {
    Navigation(this.navStack) {
      Column() {
        Image($r("app.media.app_icon")).height(42).aspectRatio(1);
        Text($r("app.string.app_name")).fontSize(20).margin({ top: AppDimens.commonSpacing / 2 });
        Text("ftp4h (ftp for Harmony) 是适用于Harmony的ftp客户端")
          .fontSize(14)
          .margin({ top: AppDimens.commonSpacing })
          .textAlign(TextAlign.Center);
        Column() {
          Row() {
            Text("地址:").labelStyle().maxFontSize(15).minFontSize(12);
            TextInput({
              text: this.address,
              placeholder: `例如 192.168.1.1`
            })
              .inputStyle()
              .placeholderFont({ size: 13 })
              .onChange((str) => {
                this.address = str;
              });
          }.alignItems(VerticalAlign.Center).margin({ top: AppDimens.commonSpacing });


          Row() {
            Text("端口:").labelStyle().maxFontSize(15).minFontSize(12);
            TextInput({ text: this.port.toString(), placeholder: "例如 21" })
              .inputStyle()
              .placeholderFont({ size: 13 })
              .onChange((str) => {
                this.port = parseInt(str);
              })
              .type(InputType.Number);
          }.alignItems(VerticalAlign.Center).margin({ top: AppDimens.commonSpacing });

          Row() {
            Text("编码:").labelStyle().maxFontSize(15).minFontSize(12);
            Text("UTF-8").layoutWeight(this.valueWeight);
          }.alignItems(VerticalAlign.Center).margin({ top: AppDimens.commonSpacing });

          Button() {
            Row() {
              Checkbox({ name: "checkbox1", group: "cg" })
                .select(this.isAnonymous)
                .hitTestBehavior(HitTestMode.None)
                .shape(CheckBoxShape.ROUNDED_SQUARE);
              Text("匿名").fontSize(15);
            }
            .padding({
              left: AppDimens.commonSpacing,
              right: AppDimens.commonSpacing,
              top: AppDimens.commonSpacing / 2,
              bottom: AppDimens.commonSpacing / 2
            });
          }
          .align(Alignment.Start)
          .margin({ top: AppDimens.commonSpacing })
          .backgroundColor(Color.Transparent).onClick(() => {
            this.isAnonymous = !this.isAnonymous;
            if (this.isAnonymous) {
              this.account = "anonymous";
              this.password = "";
            }
          });


          Row() {
            Text("用户:").labelStyle().maxFontSize(15).minFontSize(12);
            TextInput({ text: this.account })
              .inputStyle()
              .enabled(!this.isAnonymous)
              .onChange((str) => this.account = str);
          }.alignItems(VerticalAlign.Center).margin({ top: AppDimens.commonSpacing });

          Row() {
            Text("密码:").labelStyle().maxFontSize(15).minFontSize(12);
            TextInput({ text: this.password })
              .inputStyle()
              .type(InputType.Password)
              .enabled(!this.isAnonymous)
              .onChange((str) => this.password = str);
          }.alignItems(VerticalAlign.Center).margin({ top: AppDimens.commonSpacing });
        }
        .alignItems(HorizontalAlign.Start).margin({ top: AppDimens.commonSpacing * 2 });

        Blank().height(AppDimens.commonSpacing * 4);
        Button("连接", { buttonStyle: ButtonStyleMode.NORMAL }).width("100%").onClick(() => this.connectToServer());
      }
      .justifyContent(FlexAlign.Center)
      .padding(AppDimens.commonSpacing * 4)
      .width("100%")
      .height("100%");
    }
    .mode(NavigationMode.Stack)
    .width("100%")
    .height("100%");
  }

  connectToServer() {
    if (!this.address) {
      this.getUIContext().getPromptAction().showToast({ message: "address cant be empty" });
      return;
    }
    if (!this.port) {
      this.getUIContext().getPromptAction().showToast({ message: "port cant be empty" });
      return;
    }
    if (!this.account) {
      this.getUIContext().getPromptAction().showToast({ message: "account cant be empty" });
      return;
    }
    const ftpUser: FtpUser = {
      address: this.address,
      port: this.port,
      encoding: "utf-8",
      account: this.account,
      password: this.password
    };
    this.navStack.pushPath({ name: "FtpPage", param: ftpUser });
  }
}