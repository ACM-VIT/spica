export default function providerExtension(pi) {
    pi.registerCommand("spica-refresh-models", {
        description: "Refresh models after provider connection",
        handler: async (_args, ctx) => {
            await ctx.modelRegistry.refresh({ allowNetwork: false });
        },
    });
}
