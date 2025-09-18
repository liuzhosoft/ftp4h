import { FtpClient } from "@liuzhosoft/ftp4h";
import { FtpUser } from "../model/FtpUser";
import { JSON } from "@kit.ArkTS";
import AppDimens from "../ui/AppDimens";

@Builder
export function FtpPageBuilder() {
  FtpPage();
}

@ComponentV2
struct FtpPage {
  navStack?: NavPathStack;
  @Local ftpUser?: FtpUser;
  @Local status: "connecting" | "connected" | "error" = "connecting";
  @Local errMsg?: string;
  ftpClient?: FtpClient;

  build() {
    NavDestination() {
      if (this.ftpUser) {
        this.buildContent();
      }
    }.onReady((data) => {
      this.navStack = data.pathStack;
      this.ftpUser = data.pathInfo.param as FtpUser;
      this.connectServer(this.ftpUser);
    })
    .width("100%")
    .height("100%");
  }

  /**
   * 创建ftpClient实例并登录到目标服务器
   */
  connectServer(ftpUser: FtpUser) {
    this.ftpClient = new FtpClient();
    this.ftpClient.access({
      host: ftpUser.address,
      port: ftpUser.port,
      user: ftpUser.account,
      password: ftpUser.password,
      encoding: "utf-8"
    }).then((success) => {
      if (success) {
        this.status = "connected";
      } else {
        this.status = "error";
        this.errMsg = "connect failed";
      }
    }).catch((e: Error) => {
      this.status = "error";
      this.errMsg = JSON.stringify(e);
    });
  }

  @Builder
  buildContent() {
    if (this.status === "connecting") {
      Column() {
        LoadingProgress().height(56).aspectRatio(1);
        Text("Connecting...");
      }.width("100%").height("100%").alignItems(HorizontalAlign.Center).justifyContent(FlexAlign.Center);
    } else if (this.status === "error") {
      Column() {
        Text("Error");
        Text(this.errMsg ?? "unknown error.");
      }.width("100%").height("100%").alignItems(HorizontalAlign.Center).justifyContent(FlexAlign.Center);
    } else if (this.status === "connected") {
      Column() {
        Text(`Connected to ${this.ftpUser?.address}:${this.ftpUser?.port}`);
        Blank().height(AppDimens.commonSpacing * 4);
        Button("View files", { buttonStyle: ButtonStyleMode.NORMAL }).onClick(() => {
          // TODO
        });
      }.width("100%").height("100%").alignItems(HorizontalAlign.Center).justifyContent(FlexAlign.Center);
    }
  }
}