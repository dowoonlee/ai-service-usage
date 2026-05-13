// recover-by-github 함수가 클라이언트로부터 받은 GitHub access token이 정말로
// 본인 것인지 GitHub API로 확인. 토큰만 받고 신뢰하면 누구나 임의 user_id를 자처할 수 있음.

export interface GitHubUser {
  login: string;
  id: number;
}

export async function fetchGitHubUser(token: string): Promise<GitHubUser> {
  const resp = await fetch("https://api.github.com/user", {
    headers: {
      "Authorization": `Bearer ${token}`,
      "Accept": "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "AIUsage-Ranking/1.0",
    },
  });
  if (!resp.ok) {
    throw new Error(`GitHub API ${resp.status}`);
  }
  const json = await resp.json();
  if (typeof json.login !== "string" || typeof json.id !== "number") {
    throw new Error("Invalid GitHub user response");
  }
  return { login: json.login, id: json.id };
}
