import argparse
import logging
import re
import os
from typing import List, Optional

import dotenv

from src.integrations.llm import generate_response
from src.integrations.vlm import generate_response as generate_vlm_response
from src.parser.pdf import pdf_page_to_image
from src.util import Answer, read_train_json

dotenv.load_dotenv()

_logger = logging.getLogger("eval")


def llm_judge(origin_text: str, text: str) -> Optional[float]:
    """
    使用大模型评估两个文本的相关性/相似性

    Args:
        origin_text: 原始文本（参考文本或查询）
        text: 待评估的文本

    Returns:
        相似性评分，范围 0.0-1.0
    """
    if origin_text == text:
        return 1.0

    prompt = f"""你是一个专业的文本相关性/相似性评估专家。请评估以下两个文本之间的语义相关性和相似度，特别关注数值、日期、金额等关键信息的准确性。

原始文本（参考）: {origin_text}

待评估文本: {text}

评分标准（0.0-1.0分，与检索系统评分范围一致）：
- 0.95-1.0: 极高相关性/相似性，语义高度一致，主题、内容、意图几乎完全相同，并且所有关键数值、日期、金额等信息完全一致
- 0.85-0.94: 高度相关/相似，核心语义一致，主题高度匹配，存在细微差异，并且所有关键数值、日期、金额等信息完全一致
- 0.75-0.84: 高度相关/相似，主要语义一致，主题匹配，但存在一定差异，关键数值、日期、金额等信息基本一致
- 0.65-0.74: 中等相关/相似，语义部分一致，主题相关，但侧重点或细节有所不同，关键数值、日期、金额等信息基本一致
- 0.60-0.64: 中等相关/相似，语义有一定重叠，主题相关，但侧重点或细节有所不同，关键数值、日期、金额等信息有轻微偏差
- 0.55-0.59: 中等相关/相似，语义有一定重叠，主题相关，但侧重点或细节有所不同，关键数值、日期、金额等信息存在明显差异
- 0.45-0.54: 低度相关/相似，语义关联性较弱，主题有一定关联，但差异明显，关键数值、日期、金额等信息存在明显差异
- 0.35-0.44: 低度相关/相似，语义关联性很弱，主题略有相关，但差异较大，关键数值、日期、金额等信息存在重大差异
- 0.25-0.34: 几乎不相关/相似，语义几乎无关联，主题关联性有限，关键数值、日期、金额等信息严重不匹配
- 0.15-0.24: 不相关/不相似，语义无关联，主题完全不同，关键数值、日期、金额等信息完全不匹配
- 0.05-0.14: 完全不相关/不相似，语义完全无关，主题完全无关，关键数值、日期、金额等信息完全不匹配
- 0.0-0.04: 无关或空内容

评分原则（按重要性排序）：
1. **数值准确性（最重要）**：严格检查数值、日期、年份、金额、百分比、数量等关键信息的准确性。如果关键数值不匹配（如"2012年"vs"2013年"、"100万元"vs"200万元"），即使语义相似，也应大幅降低分数。关键数值错误应导致分数不超过0.6分。
2. 语义相似性：评估两个文本在语义层面的相似程度，包括核心概念、主题、意图的一致性
3. 内容重叠度：评估两个文本在具体内容、信息、细节上的重叠程度
4. 主题相关性：评估两个文本在主题、领域、话题上的相关程度
5. 上下文关联性：评估两个文本在上下文语境中的关联强度

特别注意事项：
- 对于包含数值、日期、年份、金额、百分比等关键信息的答案，必须严格检查这些信息的准确性
- 如果待评估文本中的关键数值与原始文本不一致，即使其他内容相似，也应显著降低分数
- 例如：原始文本说"成立于2012年"，待评估文本说"成立于2013年"，虽然语义高度相关，但由于关键年份错误，分数不应超过0.6分
- 数值错误越关键（如核心数据、关键日期），扣分应越严重

你必须以 JSON 的形式输出，输出的 JSON 需遵守以下的格式：
```json
{{
    "score": 0.62
}}
```
"""

    try:
        # 调用大模型API
        response = generate_response(
            [
                {"role": "user", "content": prompt},
            ],
            model="qwen-max",
        )

        # 从响应中提取评分
        similarity = extract_score(response)

    except Exception as e:
        logging.error(f"Error in llm_judge: {e}")
        similarity = None

    return similarity
    

def vision_judge_page(question: str, pdf_path: str, page_num: int) -> Optional[float]:
    """
    使用视觉模型判断指定页码是否回答了问题

    Args:
        question: 问题文本
        pdf_path: PDF文件路径
        page_num: 页码（从1开始）

    Returns:
        评分值（0.0-1.0），表示该页码是否回答了问题，如果失败则返回None
    """

    prompt = f"""你是一个专业的文档问答评估专家。请评估给定的PDF页面图像是否回答了以下问题。

问题: {question}

请仔细查看页面图像中的内容，判断该页面是否包含能够回答上述问题的信息。

评分标准（0.0-1.0分）：
- 0.9-1.0: 页面明确且完整地回答了问题，包含问题的核心答案
- 0.7-0.89: 页面包含了能够回答问题的相关信息，答案基本完整
- 0.5-0.69: 页面包含部分相关信息，但答案不够完整或明确
- 0.3-0.49: 页面与问题有一定关联，但信息不足以回答问题
- 0.1-0.29: 页面与问题关联性较弱，基本无法回答问题
- 0.0-0.09: 页面与问题无关，完全不包含回答问题的信息

请只返回一个0.0到1.0之间的浮点数评分，不要包含任何其他文字说明。"""

    page_image_path = pdf_page_to_image(pdf_path, page_num, dpi=100)

    try:
        # 调用视觉模型API
        response = generate_vlm_response(prompt, images=page_image_path)
        # 从响应中提取评分
        score = extract_score(response)
        if score >= 0.9:
            score = 1.0
        elif score >= 0.7:
            score = 0.89
        elif score >= 0.5:
            score = 0.69
        elif score >= 0.3:
            score = 0.49
        elif score >= 0.1:
            score = 0.09
        elif score > 0.0:
            score = 0.09
        return score
    except Exception as e:
        _logger.warning(f"Error in vision_judge_page: {e}")
        return None


def extract_score(response_text: str) -> float:
    """
    从大模型响应中提取评分

    Args:
        response_text: 大模型返回的文本

    Returns:
        评分值（0.0-1.0）
    """
    # 尝试直接提取浮点数
    # 匹配0.0到1.0之间的浮点数
    pattern = r"\b(0\.\d+|1\.0|1)\b"
    matches = re.findall(pattern, response_text)

    if matches:
        try:
            score = float(matches[0])
            # 确保分数在0.0-1.0范围内
            if score < 0.0:
                return 0.0
            elif score > 1.0:
                return 1.0
            return score
        except ValueError:
            pass

    # 如果找不到数字，尝试其他格式
    # 例如：评分：0.85 或 score: 0.85
    pattern = r"[0-1]\.?\d*"
    matches = re.findall(pattern, response_text)

    if matches:
        try:
            score = float(matches[0])
            if score < 0.0:
                return 0.0
            elif score > 1.0:
                return 1.0
            return score
        except ValueError:
            pass

    # 如果都提取不到，返回默认值0.0
    logging.warning(f"Warning: Could not extract score from response: {response_text}")
    return 0.0


def evaluation_all(dataset_dir: str, player_answers: List[Answer], normal_answers: List[Answer]) -> float:
    _logger.info(
        "Starting answer evaluation, player_answers count: %d, normal_answers count: %d",
        len(player_answers),
        len(normal_answers),
    )

    if len(player_answers) != len(normal_answers):
        _logger.error(
            "Answer count mismatch: player_answers=%d, normal_answers=%d",
            len(player_answers),
            len(normal_answers),
        )
        raise ValueError("answers must have same length")

    score = 0.0
    count = 0
    total_items = len(player_answers)
    failed_items = 0

    _logger.info("Starting item-by-item evaluation, total items: %d", total_items)

    for idx, (player_answer, normal_answer) in enumerate(
        zip(player_answers, normal_answers), 1
    ):
        _logger.info(
            "Evaluating item %d/%d: question='%s'",
            idx,
            total_items,
            player_answer.question[:50] if player_answer.question else "",
        )

        s = evaluation(dataset_dir, player_answer, normal_answer)
        if s is None:
            failed_items += 1
            _logger.info("Item %d/%d evaluation failed, skipping", idx, total_items)
            continue

        score += s
        count += 1
        _logger.info(
            "Item %d/%d score: %.4f (cumulative score: %.4f, valid items: %d)",
            idx,
            total_items,
            s,
            score,
            count,
        )

    if count == 0:
        _logger.error("All evaluation items failed, cannot calculate average score")
        raise ValueError("All evaluations failed, cannot calculate average score")

    final_score = score / count
    _logger.info(
        "Evaluation completed: total_items=%d, successful_items=%d, failed_items=%d, total_score=%.4f, average_score=%.4f",
        total_items,
        count,
        failed_items,
        score,
        final_score,
    )

    return final_score


def evaluation(dataset_dir: str, player_answer: Answer, normal_answer: Answer) -> Optional[float]:
    _logger.debug(
        "Evaluating single answer: question='%s'",
        player_answer.question[:50] if player_answer.question else "",
    )

    answer_score = llm_judge(
        normal_answer.answer,
        player_answer.answer,
    )

    if answer_score is None:
        _logger.warning(
            "LLM evaluation failed: question='%s'",
            player_answer.question[:50] if player_answer.question else "",
        )
        return None

    filename_score = 0.0
    page_score = 0.0
    file_match_score = 0.0

    if player_answer.filename == normal_answer.filename:
        filename_score = 1.0
        _logger.debug("Filename matched: '%s'", player_answer.filename)
        if player_answer.page == normal_answer.page:
            page_score = 1.0
            _logger.debug("Page number matched: %d", player_answer.page)
        else:
            _logger.debug("Page number mismatch: player=%d, normal=%d", player_answer.page, normal_answer.page)
        file_match_score = (filename_score + page_score) / 2
    

    # 过低答案得分说明选手回答不准确，页面内信息不足以回答问题，
    # 因此仅在答案得分大于0.6且页码不匹配时，使用视觉模型判断页码是否回答了问题
    pdf_path = os.path.join(dataset_dir, player_answer.filename)
    if answer_score > 0.6 and page_score == 0.0 and os.path.exists(pdf_path):
        vision_score = vision_judge_page(
            player_answer.question,
            pdf_path,
            player_answer.page
        )
        if vision_score is not None:
            file_match_score = vision_score
            _logger.debug("Page %d vision score: %.4f (question: '%s')", player_answer.page, vision_score, player_answer.question[:50] if player_answer.question else "")
    else:
        _logger.debug(
            "Filename mismatch: player='%s', normal='%s'",
            player_answer.filename,
            normal_answer.filename,
        )

    final_score = file_match_score * 30 + answer_score * 70
    _logger.debug(
        "Item score calculation: answer_score=%.4f, file_match_score=%.4f, final_score=%.4f",
        answer_score,
        file_match_score,
        final_score,
    )

    return final_score


def run(
    dataset_dir: str,
    output_file: str,
    answers_file: str,
) -> float:
    outputs = read_train_json(output_file)
    answers = read_train_json(answers_file)

    return evaluation_all(dataset_dir, outputs, answers)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Evaluate answers against ground truth",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python3 eval.py --dataset ./data/dataset/ --output ./data/output.json --answer ./data/train.json
        """,
    )
    parser.add_argument(
        "--dataset",
        type=str,
        default="./data/dataset/",
        help="Path to dataset directory (default: ./data/dataset/)",
    )
    parser.add_argument(
        "--output",
        type=str,
        default="./data/output.json",
        help="Path to the output JSON file (player answers)",
    )
    parser.add_argument(
        "--answer",
        type=str,
        default="./data/answer.json",
        help="Path to the answer JSON file (ground truth)",
    )

    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG,
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    )

    try:
        final_score = run(args.dataset, args.output, args.answer)
        _logger.info(f"\nFinal evaluation score: {final_score:.4f}")
    except Exception as e:
        _logger.error(f"Evaluation failed: {e}", exc_info=True)
        exit(1)
