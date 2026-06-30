"""Knowledge base tools — create and enumerate knowledge bases."""

from mcp.server.fastmcp import FastMCP, Context

from config import settings


def register(mcp: FastMCP, get_user_id, fs_factory) -> None:

    @mcp.tool(
        name="create_knowledge_base",
        description=(
            "Create a new knowledge base and scaffold starter overview/log pages.\n\n"
            "Each knowledge base is independent — different topics, different documents, different wiki pages. "
            "Use `knowledge_base=<slug>` (the name you provide here) with all other tools to target it.\n\n"
            "Set kind='course' to create a course instead of a wiki. Default 'wiki'."
        ),
    )
    async def create_knowledge_base(
        ctx: Context,
        name: str,
        description: str = "",
        kind: str = "wiki",
    ) -> str:
        name = name.strip()
        description = description.strip()
        if not name:
            return "Error: name is required when creating a knowledge base."
        if len(name) > 120:
            return "Error: knowledge base name must be 120 characters or fewer."
        if kind not in ("wiki", "course"):
            return "Error: kind must be 'wiki' or 'course'."

        user_id = get_user_id(ctx)
        fs = fs_factory(user_id)
        kb = await fs.create_knowledge_base(name, description or None, kind)

        if kb.get("already_exists"):
            return f"Knowledge base already exists: **{kb['name']}** (`{kb['slug']}`)."

        label = "course" if kind == "course" else "knowledge base"
        return (
            f"Created {label} **{kb['name']}** (`{kb['slug']}`). "
            "Starter pages were added at `/wiki/overview.md` and `/wiki/log.md`. "
            f"Use `knowledge_base=\"{kb['slug']}\"` with the other tools."
        )

    @mcp.tool(
        name="list_knowledge_bases",
        description=(
            "List the user's knowledge bases with their names and slugs.\n\n"
            "Every other tool takes a `knowledge_base` slug — call this first to "
            "discover the valid slugs, or whenever you need to confirm which "
            "knowledge bases exist."
        ),
    )
    async def list_knowledge_bases(ctx: Context) -> str:
        user_id = get_user_id(ctx)
        fs = fs_factory(user_id)
        kbs = await fs.list_knowledge_bases()
        if not kbs:
            return (
                "No knowledge bases yet. Use `create_knowledge_base`, "
                f"or create one at {settings.APP_URL}/wikis."
            )

        lines = [f"- **{kb['name']}** (`{kb['slug']}`)" for kb in kbs]
        return "\n".join(lines)
