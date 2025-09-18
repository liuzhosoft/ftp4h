import common from "@ohos.app.ability.common";

class GlobalRes {
  private context?: common.UIAbilityContext = undefined;

  getContext(): common.UIAbilityContext {
    if (!this.context) {
      throw Error("init first.");
    }
    return this.context;
  }

  init(context: common.UIAbilityContext): void {
    this.context = context;
  }
}

export default new GlobalRes();